// Browser security headers (audit F15, 27 Sep 2026). Response-specific:
//
// - API origin (api.snaglist.dev and the staging API): JSON, private media, the
//   Contractor link page, the email-link fallback page and the Apple association file.
//   A policy the container already set on a response (the Contractor page, the
//   fallback page, report downloads) is kept exactly; it knows its own resources.
//   Anything else gets a policy that loads nothing (non-HTML) or, for an older HTML
//   page that still uses inline script, one that only forbids framing, plugins and
//   base rewriting, so it cannot break it.
// - Portal origin: the single-page app document gets a policy that admits exactly
//   what it loads — its own bundle, Google Identity Services (script, style, iframe,
//   fetch under accounts.google.com/gsi/) and the Apple button image. Apple sign-in on
//   the web is a top-level navigation and form_post back to our own callback, which
//   no policy on our page governs.
//
// Mode (`BROWSER_SECURITY_HEADERS`): `report-only` sends only
// Content-Security-Policy-Report-Only (observe, change nothing); `enforce` sends the
// policy and nosniff, frame denial, Permissions-Policy and HSTS. Absent means
// report-only, so an older configuration never starts enforcing by accident. Any
// other value is treated as `enforce` (a typo must not weaken anything). HSTS never
// carries includeSubDomains or preload: it covers exactly the host that sent it.

export const apiResourcePolicy = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
export const apiDocumentPolicy = "frame-ancestors 'none'; object-src 'none'; base-uri 'self'";
export const portalDocumentPolicy = [
  "default-src 'self'",
  "script-src 'self' https://accounts.google.com/gsi/client",
  "style-src 'self' 'unsafe-inline' https://accounts.google.com/gsi/style",
  "img-src 'self' data: blob: https://appleid.cdn-apple.com",
  "font-src 'self'",
  "connect-src 'self' https://accounts.google.com/gsi/",
  "frame-src https://accounts.google.com/gsi/",
  "worker-src 'none'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'"
].join('; ');
export const permissionsPolicy = 'camera=(self), microphone=(), geolocation=(), payment=(), usb=(), display-capture=()';
export const strictTransportSecurity = 'max-age=31536000';

export function securityMode(env) {
  const value = env ? env.BROWSER_SECURITY_HEADERS : undefined;
  if (value === undefined) return 'report-only';
  return value === 'report-only' ? 'report-only' : 'enforce';
}

function isHTML(headers) {
  return headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() === 'text/html';
}

function applyPolicy(headers, policy, mode) {
  // A response-specific policy set upstream always wins; never stack a second one.
  if (headers.has('Content-Security-Policy') || headers.has('Content-Security-Policy-Report-Only')) return;
  headers.set(mode === 'enforce' ? 'Content-Security-Policy' : 'Content-Security-Policy-Report-Only', policy);
}

function applyEnforced(headers, document) {
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Strict-Transport-Security', strictTransportSecurity);
  if (document) {
    if (!headers.has('X-Frame-Options')) headers.set('X-Frame-Options', 'DENY');
    headers.set('Permissions-Policy', permissionsPolicy);
  }
}

/** Headers for a response from the API Worker (all paths). */
export function apiSecurityResponse(response, env) {
  const mode = securityMode(env);
  const headers = new Headers(response.headers);
  const document = isHTML(headers);
  applyPolicy(headers, document ? apiDocumentPolicy : apiResourcePolicy, mode);
  if (mode === 'enforce') applyEnforced(headers, document);
  return new Response(response.body, {status: response.status, statusText: response.statusText, headers});
}

/** Headers for a portal static asset or the SPA document. API responses proxied
 *  through the portal already carry the API Worker's headers and are only given
 *  the transport/sniffing controls here. */
export function portalSecurityResponse(response, env, {api = false} = {}) {
  const mode = securityMode(env);
  const headers = new Headers(response.headers);
  const document = !api && isHTML(headers);
  applyPolicy(headers, document ? portalDocumentPolicy : apiResourcePolicy, mode);
  if (mode === 'enforce') applyEnforced(headers, document);
  return new Response(response.body, {status: response.status, statusText: response.statusText, headers});
}
