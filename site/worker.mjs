// Site worker: owns context.daddyrad.com end to end.
// /download retains the manual bootstrap route. /updates/ serves only bundled
// signed-feed assets; all other paths proxy the existing landing.
import release from './release.json' with { type: 'json' };

const PAGES_HOST = 'contextdaddy-landing.pages.dev';
/** @param {Response} response */
function secure(response) {
  const result = new Response(response.body, response);
  result.headers.set('X-Content-Type-Options', 'nosniff');
  result.headers.set('Referrer-Policy', 'no-referrer');
  result.headers.set('Content-Security-Policy', "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  return result;
}
export default {
  /** @param {Request} request @param {Env} env */
  async fetch(request, env) {
    if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    const url = new URL(request.url);
    if (url.hostname !== 'context.daddyrad.com') {
      return new Response('Not found', { status: 404 });
    }
    if (url.pathname === '/download') {
      const assetURL = new URL(request.url);
      assetURL.pathname = release.path;
      assetURL.search = '';
      const response = await env.ASSETS.fetch(new Request(assetURL, request));
      const result = secure(response);
      if (response.ok) {
        result.headers.set('Content-Type', 'application/x-apple-diskimage');
        result.headers.set('Content-Disposition', `attachment; filename="${release.filename}"`);
        result.headers.set('Cache-Control', 'private, no-store');
      }
      return result;
    }
    if (url.pathname.startsWith('/updates/')) {
      return secure(await env.ASSETS.fetch(request));
    }
    const origin = new URL(request.url);
    origin.host = PAGES_HOST;
    const upstream = new Request(origin, request);
    upstream.headers.set('x-daddy-proxy', '1');
    return fetch(upstream);
  },
};
