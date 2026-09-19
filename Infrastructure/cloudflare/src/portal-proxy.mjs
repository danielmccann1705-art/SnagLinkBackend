import {backendRequest, privateResponse} from './proxy.mjs';

export const portalOrigin = 'https://staging-app.usesnaglist.com';
export const productionPortalOrigin = 'https://app.usesnaglist.com';

// The browser talks to its own origin. A service binding, rather than an
// arbitrary URL supplied in configuration/request data, reaches the candidate.
// Do not rewrite Origin, CSRF, host-only cookies or provider challenge bindings.
export async function portalResponse(request, env) {
  return responseFor(request, env, portalOrigin,
    env.STAGING_PORTAL_ENABLED === 'true' && env.PRODUCTION_PORTAL_ENABLED === undefined);
}

export async function productionPortalResponse(request, env) {
  return responseFor(request, env, productionPortalOrigin,
    env.PRODUCTION_PORTAL_ENABLED === 'true' && env.STAGING_PORTAL_ENABLED === undefined);
}

async function responseFor(request, env, expectedOrigin, enabled) {
  const url = new URL(request.url);
  if (!enabled || env.PORTAL_ORIGIN !== expectedOrigin ||
      !env.BACKEND?.fetch || !env.ASSETS?.fetch) {
    return privateResponse(new Response('Snaglist is awaiting configuration.', {status:503}));
  }
  if (url.origin !== expectedOrigin) {
    return privateResponse(new Response('Open the Snaglist portal address.', {status:421}));
  }
  if (url.pathname.startsWith('/api/v2/') || url.pathname === '/health') {
    try {
      return privateResponse(await env.BACKEND.fetch(backendRequest(request)));
    } catch {
      // No retry of writes, and no transport exception/token URL in logs.
      return privateResponse(new Response('Snaglist could not reach the service. Please retry.', {status:503}));
    }
  }
  // Never turn API errors or a Contractor link on the wrong host into an SPA
  // success page. Contractor writes retain their separate exact BASE_URL check.
  if (/^\/(?:api|m|link|preview|internal)(?:\/|$)/.test(url.pathname)) {
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
