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

test('retains API proxy behavior on the Pages origin', async () => {
  const original = globalThis.fetch;
  let requested;
  globalThis.fetch = async (input) => { requested = input.url; return new Response('landing', { status: 200 }); };
  try {
    const response = await worker.fetch(new Request('https://context.daddyrad.com/api/ai?a=1'), env);
    assert.equal(response.status, 200);
    assert.equal(requested, 'https://contextdaddy-landing.pages.dev/api/ai?a=1');
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

test('known web routes redirect directly with exact queries', async () => {
  const routes = [
    ['/', '/'], ['/index.html', '/'], ['/index.md', '/index.md'],
    ['/llms.txt', '/llms.txt'], ['/llms-full.txt', '/llms-full.txt'],
    ['/ai.txt', '/ai.txt'], ['/sitemap.xml', '/sitemap.xml'],
    ['/blog/rss.xml', '/blog/rss.xml'],
  ];
  for (const section of ['privacy', 'terms', 'support', 'accessibility', 'release', 'testflight', 'blog']) {
    routes.push([`/${section}`, `/${section}/`], [`/${section}/`, `/${section}/`],
      [`/${section}/index.html`, `/${section}/`], [`/${section}/index.md`, `/${section}/index.md`],
      [`/${section}.md`, `/${section}/index.md`]);
  }
  const query = '?utm_source=old&keep=a%2Fb&keep=%25';
  for (const host of ['context.daddyrad.com']) {
    for (const method of ['GET', 'HEAD']) for (const [path, target] of routes) {
      const response = await worker.fetch(new Request('https://' + host + path + query, { method }), env);
      assert.equal(response.status, 308, `${method} ${host}${path}`);
      assert.equal(response.headers.get('location'), 'https://daddyrad.com/context' + target + query);
      assert.equal(await response.text(), '');
    }
  }
});

test('API, metadata, static resources and unknown paths retain the existing proxy behavior', async () => {
  const original = globalThis.fetch;
  const query = '?keep=a%2Fb';
  let requested;
  let status;
  globalThis.fetch = async (request) => {
    requested = request;
    return new Response('upstream', { status, headers: { 'Content-Type': 'application/json' } });
  };
  try {
    for (const path of ['/api/ai', '/api/md', '/api/md/_catalog', '/openapi.json', '/robots.txt', '/release.json', '/downloads/missing.dmg', '/releases/missing.dmg', '/download/', '/assets/missing.png', '/missing', '/blog/missing/', '/blog/missing.md', '/blog/background-apps/']) {
      status = path.startsWith('/api/') || path === '/openapi.json' || path === '/robots.txt' ? 200 : 404;
      for (const method of ['GET', 'HEAD']) {
        const response = await worker.fetch(new Request('https://context.daddyrad.com' + path + query, { method }), env);
        assert.equal(response.status, status, `${method} ${path}`);
        assert.equal(response.headers.get('location'), null);
        assert.equal(requested.url, 'https://contextdaddy-landing.pages.dev' + path + query);
        assert.equal(requested.method, method);
        assert.equal(requested.headers.get('x-daddy-proxy'), '1');
      }
    }
  } finally {
    globalThis.fetch = original;
  }
  const missing = { ASSETS: { fetch: async () => new Response('missing', { status: 404 }) } };
  for (const path of ['/download', '/updates/missing.dmg']) {
    const response = await worker.fetch(new Request('https://context.daddyrad.com' + path), missing);
    assert.equal(response.status, 404);
    assert.equal(response.headers.get('location'), null);
  }
});

test('non-GET methods retain their existing rejection contract', async () => {
  for (const host of ['context.daddyrad.com']) {
    for (const path of ['/', '/release', '/release.json', '/api/ai', '/api/md']) {
      for (const method of ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
        const response = await worker.fetch(new Request('https://' + host + path, { method }), env);
        assert.equal(response.status, 405);
        assert.equal(response.headers.get('allow'), 'GET, HEAD');
        assert.equal(response.headers.get('location'), null);
      }
    }
  }
});
