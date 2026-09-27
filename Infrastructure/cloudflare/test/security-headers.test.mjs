import test from 'node:test';
import assert from 'node:assert/strict';
import {apiSecurityResponse, portalSecurityResponse, securityMode, apiResourcePolicy, apiDocumentPolicy,
  portalDocumentPolicy, permissionsPolicy, strictTransportSecurity} from '../src/security-headers.mjs';
import {portalResponse, portalOrigin} from '../src/portal-proxy.mjs';
import {candidateConfigs, candidateSecurityHeaders} from '../scripts/candidate-config.mjs';

const html = (body = '<!doctype html><title>x</title>', headers = {}) =>
  new Response(body, {headers: {'Content-Type': 'text/html; charset=utf-8', ...headers}});
const json = () => new Response('{"ok":true}', {headers: {'Content-Type': 'application/json'}});

test('mode: absent observes only, a typo enforces, and only two words are meaningful', () => {
  assert.equal(securityMode({}), 'report-only');
  assert.equal(securityMode(undefined), 'report-only');
  assert.equal(securityMode({BROWSER_SECURITY_HEADERS: 'report-only'}), 'report-only');
  assert.equal(securityMode({BROWSER_SECURITY_HEADERS: 'enforce'}), 'enforce');
  assert.equal(securityMode({BROWSER_SECURITY_HEADERS: 'Report-Only'}), 'enforce');
  assert.equal(securityMode({BROWSER_SECURITY_HEADERS: ''}), 'enforce');
});

test('report-only changes nothing but adds the report-only policy', () => {
  const env = {BROWSER_SECURITY_HEADERS: 'report-only'};
  const api = apiSecurityResponse(json(), env);
  assert.equal(api.headers.get('Content-Security-Policy-Report-Only'), apiResourcePolicy);
  for (const name of ['Content-Security-Policy', 'X-Frame-Options', 'X-Content-Type-Options', 'Strict-Transport-Security', 'Permissions-Policy']) {
    assert.equal(api.headers.get(name), null, name);
  }
  const doc = portalSecurityResponse(html(), env);
  assert.equal(doc.headers.get('Content-Security-Policy-Report-Only'), portalDocumentPolicy);
  assert.equal(doc.headers.get('Content-Security-Policy'), null);
});

test('API: JSON and media load nothing and cannot be framed; the policy a page set upstream wins', async () => {
  const env = {BROWSER_SECURITY_HEADERS: 'enforce'};
  const api = apiSecurityResponse(json(), env);
  assert.equal(api.headers.get('Content-Security-Policy'), apiResourcePolicy);
  assert.equal(api.headers.get('X-Content-Type-Options'), 'nosniff');
  assert.equal(api.headers.get('Strict-Transport-Security'), strictTransportSecurity);
  assert.doesNotMatch(strictTransportSecurity, /includeSubDomains|preload/i);
  assert.equal(api.headers.get('Permissions-Policy'), null, 'only documents carry a Permissions-Policy');
  assert.equal(await api.text(), '{"ok":true}');
  const image = apiSecurityResponse(new Response(new Uint8Array([255, 216, 255]), {headers: {'Content-Type': 'image/jpeg'}}), env);
  assert.deepEqual(new Uint8Array(await image.arrayBuffer()), new Uint8Array([255, 216, 255]));
  assert.equal(image.headers.get('Content-Type'), 'image/jpeg');
  // The Contractor page and the email-link fallback page carry their own policy.
  const contractorPolicy = "default-src 'self'; script-src 'self'; frame-ancestors 'self'";
  const contractor = apiSecurityResponse(html('page', {'Content-Security-Policy': contractorPolicy, 'X-Frame-Options': 'SAMEORIGIN'}), env);
  assert.equal(contractor.headers.get('Content-Security-Policy'), contractorPolicy);
  assert.equal(contractor.headers.get('Content-Security-Policy-Report-Only'), null);
  assert.equal(contractor.headers.get('X-Frame-Options'), 'SAMEORIGIN');
  assert.equal(contractor.headers.get('Permissions-Policy'), permissionsPolicy);
  // An older HTML page with inline script only loses framing, plugins and base rewriting.
  const legacy = apiSecurityResponse(html('<script>1</script>'), env);
  assert.equal(legacy.headers.get('Content-Security-Policy'), apiDocumentPolicy);
  assert.doesNotMatch(apiDocumentPolicy, /script-src|default-src/);
  assert.equal(legacy.headers.get('X-Frame-Options'), 'DENY');
});

test('API: status, redirects and cookies survive (Apple web callback, email sign-in)', () => {
  const headers = new Headers({Location: '/'});
  headers.append('Set-Cookie', '__Host-snaglist_session=synthetic; Path=/; Secure; HttpOnly; SameSite=Lax');
  headers.append('Set-Cookie', '__Host-snaglist_apple_x=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=None');
  const response = apiSecurityResponse(new Response(null, {status: 303, headers}), {BROWSER_SECURITY_HEADERS: 'enforce'});
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('Location'), '/');
  assert.equal(response.headers.getSetCookie().length, 2);
});

test('portal document admits its bundle, Google Identity Services and the Apple button image, and nothing else', () => {
  const directives = Object.fromEntries(portalDocumentPolicy.split('; ').map(part => {
    const [name, ...values] = part.split(' '); return [name, values];
  }));
  assert.deepEqual(directives['default-src'], ["'self'"]);
  assert.deepEqual(directives['script-src'], ["'self'", 'https://accounts.google.com/gsi/client']);
  assert.equal(directives['script-src'].includes("'unsafe-inline'"), false);
  assert.equal(directives['script-src'].includes("'unsafe-eval'"), false);
  assert.deepEqual(directives['connect-src'], ["'self'", 'https://accounts.google.com/gsi/']);
  assert.deepEqual(directives['frame-src'], ['https://accounts.google.com/gsi/']);
  assert.ok(directives['img-src'].includes('https://appleid.cdn-apple.com'));
  assert.ok(directives['img-src'].includes('blob:'), 'private photos are shown from blob: URLs');
  assert.deepEqual(directives['frame-ancestors'], ["'none'"]);
  assert.deepEqual(directives['object-src'], ["'none'"]);
});

test('portal Worker: enforced document headers, API passthrough keeps the API policy, strict-origin stays', async () => {
  const env = {STAGING_PORTAL_ENABLED: 'true', PORTAL_ORIGIN: portalOrigin, BROWSER_SECURITY_HEADERS: 'enforce',
    BACKEND: {fetch: async () => apiSecurityResponse(json(), {BROWSER_SECURITY_HEADERS: 'enforce'})},
    ASSETS: {fetch: async request => request.url.endsWith('.js')
      ? new Response('x', {headers: {'Content-Type': 'text/javascript'}}) : html()}};
  const doc = await portalResponse(new Request(portalOrigin + '/projects/synthetic'), env);
  assert.equal(doc.headers.get('Content-Security-Policy'), portalDocumentPolicy);
  assert.equal(doc.headers.get('X-Frame-Options'), 'DENY');
  assert.equal(doc.headers.get('X-Content-Type-Options'), 'nosniff');
  assert.equal(doc.headers.get('Permissions-Policy'), permissionsPolicy);
  assert.equal(doc.headers.get('Strict-Transport-Security'), strictTransportSecurity);
  assert.equal(doc.headers.get('Referrer-Policy'), 'strict-origin', 'Google still receives the registered origin');
  const script = await portalResponse(new Request(portalOrigin + '/assets/index.js'), env);
  assert.equal(script.headers.get('Content-Type'), 'text/javascript');
  assert.equal(script.headers.get('X-Content-Type-Options'), 'nosniff');
  const api = await portalResponse(new Request(portalOrigin + '/api/v2/auth/session'), env);
  assert.equal(api.headers.get('Content-Security-Policy'), apiResourcePolicy);
  assert.equal(api.headers.get('Referrer-Policy'), 'no-referrer');
  const failure = await portalResponse(new Request(portalOrigin + '/api/v2/projects', {method: 'POST'}),
    {...env, BACKEND: {fetch: async () => { throw new Error('down'); }}});
  assert.equal(failure.status, 503);
  assert.equal(failure.headers.get('Content-Security-Policy'), apiResourcePolicy);
});

test('generator: enforce by default, report-only only when asked, and a typo is refused', () => {
  assert.equal(candidateSecurityHeaders({}), 'enforce');
  assert.equal(candidateSecurityHeaders({SNAGLIST_BROWSER_SECURITY_HEADERS: 'report-only'}), 'report-only');
  assert.throws(() => candidateSecurityHeaders({SNAGLIST_BROWSER_SECURITY_HEADERS: 'on'}));
  const digest = 'sha256:' + 'a'.repeat(64);
  const on = candidateConfigs({imageDigest: digest, assetsDirectory: '/tmp/dist', environment: {}});
  assert.equal(on.backend.vars.BROWSER_SECURITY_HEADERS, 'enforce');
  assert.equal(on.portal.vars.BROWSER_SECURITY_HEADERS, 'enforce');
  const observe = candidateConfigs({imageDigest: digest, assetsDirectory: '/tmp/dist', environment: {SNAGLIST_BROWSER_SECURITY_HEADERS: 'report-only'}});
  assert.equal(observe.backend.vars.BROWSER_SECURITY_HEADERS, 'report-only');
  assert.equal(observe.portal.vars.BROWSER_SECURITY_HEADERS, 'report-only');
});
