import {backendRequest, privateResponse} from './proxy.mjs';

export const portalOrigin = 'https://staging-app.usesnaglist.com';

// The browser talks to its own origin. A service binding, rather than an
// arbitrary URL supplied in configuration/request data, reaches the candidate.
// Do not rewrite Origin, CSRF, host-only cookies or provider challenge bindings.
export async function portalResponse(request, env) {
  const url = new URL(request.url);
  if (env.STAGING_PORTAL_ENABLED !== 'true' || env.PORTAL_ORIGIN !== portalOrigin ||
      !env.BACKEND?.fetch || !env.ASSETS?.fetch) {
    return privateResponse(new Response('Snaglist staging is awaiting configuration.', {status:503}));
  }
  if (url.origin !== portalOrigin) {
    return privateResponse(new Response('Open the staging Snaglist address.', {status:421}));
  }
  if (url.pathname.startsWith('/api/v2/') || url.pathname === '/health') {
    try {
      return privateResponse(await env.BACKEND.fetch(backendRequest(request)));
    } catch {
      // No retry of writes, and no transport exception/token URL in logs.
      return privateResponse(new Response('Snaglist could not reach the staging service. Please retry.', {status:503}));
    }
  }
  // Never turn API errors or a Contractor link on the wrong host into an SPA
  // success page. Contractor writes retain their separate exact BASE_URL check.
  if (/^\/(?:api|m|link|preview)(?:\/|$)/.test(url.pathname)) {
    return privateResponse(new Response('This address is not available here.', {status:404}));
  }
  if (!['GET','HEAD'].includes(request.method)) {
    return privateResponse(new Response('Method not allowed.', {status:405, headers:{Allow:'GET, HEAD'}}));
  }
  const response = privateResponse(await env.ASSETS.fetch(request));
  if (response.ok && response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() === 'text/html') {
    // Google Identity Services must receive the site's registered origin.
    // strict-origin never discloses a route, query, fragment or token, even to
    // same-origin resources. API/Contractor/error responses stay no-referrer.
    response.headers.set('Referrer-Policy', 'strict-origin');
  }
  return response;
}
