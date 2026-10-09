import assert from 'node:assert/strict';
import { test } from 'node:test';
import release from './release.json' with { type: 'json' };
import worker from './worker.mjs';

const env = {
  ASSETS: {
    fetch: async (request) => new Response(`asset:${new URL(request.url).pathname}`, { status: 200 }),
  },
};

test('serves /download on context.daddyrad.com', async () => {
  for (const method of ['GET', 'HEAD']) {
    const response = await worker.fetch(new Request(`https://context.daddyrad.com/download`, { method }), env);
    assert.equal(response.status, 200, method);
    assert.equal(response.headers.get('Content-Type'), 'application/x-apple-diskimage');
    assert.equal(response.headers.get('Content-Disposition'), `attachment; filename="${release.filename}"`);
    assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  }
});

test('proxies non-download paths to the Pages landing', async () => {
  const original = globalThis.fetch;
  let requested;
  globalThis.fetch = async (input) => { requested = input.url; return new Response('landing', { status: 200 }); };
  try {
    const response = await worker.fetch(new Request('https://context.daddyrad.com/release/?a=1'), env);
    assert.equal(response.status, 200);
    assert.equal(requested, 'https://contextdaddy-landing.pages.dev/release/?a=1');
  } finally {
    globalThis.fetch = original;
  }
});

test('unknown hosts 404', async () => {
  const other = await worker.fetch(new Request('https://example.com/download'), env);
  assert.equal(other.status, 404);
});

test('rejects non-read methods', async () => {
  const response = await worker.fetch(new Request('https://context.daddyrad.com/download', { method: 'POST' }), env);
  assert.equal(response.status, 405);
});


test('serves the signed feed and update enclosure directly with security headers', async () => {
  for (const path of ['/updates/appcast.xml', '/updates/ContextDaddy-0.3.0-20-arm64.dmg']) {
    const response = await worker.fetch(new Request(`https://context.daddyrad.com${path}`), env);
    assert.equal(await response.text(), `asset:${path}`);
    assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
    assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  }
});

test('a missing update asset stays unavailable', async () => {
  const missing = { ASSETS: { fetch: async () => new Response('missing', { status: 404 }) } };
  const response = await worker.fetch(new Request('https://context.daddyrad.com/updates/appcast.xml'), missing);
  assert.equal(response.status, 404);
});
