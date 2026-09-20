import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {productionContainerEnvironment, productionAPIOrigin as api, productionPortalOrigin as portal} from '../src/production-config.mjs';
import {containerEnvironment} from '../src/config.mjs';
import {productionResponse, productionMaintenance} from '../src/production-backend.mjs';
import {productionPortalResponse, portalResponse} from '../src/portal-proxy.mjs';

// Synthetic credentials only. These fixtures have no associated provider account.
const key = char => Buffer.alloc(32, char).toString('base64');
function configured(overrides = {}) {
  return {
    PRODUCTION_ENABLED: 'true', PLATFORM_ENVIRONMENT: 'production',
    PRODUCTION_DATABASE_HOST: 'ep-synthetic-production.c-2.eu-west-2.aws.neon.tech',
    PRODUCTION_DATABASE_NAME: 'snaglist',
    DATABASE_URL: 'postgres://synthetic:synthetic@ep-synthetic-production.c-2.eu-west-2.aws.neon.tech/snaglist?sslmode=require',
    BASE_URL: api, MAGIC_LINK_BASE_URL: api, PORTAL_ORIGIN: portal,
    R2_ACCOUNT_ID: '387d49014cd0d45f9e6434196ab513c0',
    R2_BUCKET_NAME: 'snaglist-production-uploads', R2_PRIVATE_BUCKET_NAME: 'snaglist-production-private',
    R2_PUBLIC_URL: api, R2_PRIVATE_NAMESPACE: 'private-v1/',
    R2_ACCESS_KEY_ID: 'synthetic-access', R2_SECRET_ACCESS_KEY: 'synthetic-secret',
    JWT_SECRET: key('j'), MAINTENANCE_SECRET: key('m'), LINK_GRANT_TOKEN_KEY: key('l'),
    APPLE_CREDENTIAL_KEY: key('a'), APPLE_BUNDLE_ID: 'com.snaglist.app', APPLE_CLIENT_ID: 'com.snaglist.app',
    APPLE_TEAM_ID: '52ZZHYHM62', APPLE_KEY_ID: 'SYNTHETIC2', APPLE_PRIVATE_KEY: '-----BEGIN PRIVATE KEY----- synthetic only',
    GOOGLE_AUTH_ENVIRONMENT: 'production', GOOGLE_WEB_CLIENT_ID: '100-syntheticweb.apps.googleusercontent.com',
    GOOGLE_IOS_CLIENT_ID: '100-syntheticios.apps.googleusercontent.com',
    RESEND_API_KEY: 're_synthetic', EMAIL_FROM: 'Snaglist <notifications@mail.usesnaglist.com>',
    REVENUECAT_SECRET_API_KEY: 'synthetic-server-key', ...overrides
  };
}

test('production is disabled by default and cannot reuse the staging adapter or switches', () => {
  assert.throws(() => productionContainerEnvironment({}));
  assert.throws(() => productionContainerEnvironment(configured({PRODUCTION_ENABLED: 'false'})));
  assert.throws(() => containerEnvironment(configured()));
  for (const key of ['STAGING_ENABLED', 'STAGING_PLATFORM_ENABLED', 'STAGED_LEGACY_IMPORT_ENABLED']) {
    assert.throws(() => productionContainerEnvironment(configured({[key]: 'false'})));
  }
  assert.throws(() => productionContainerEnvironment(configured({IMPORT_PREVIEW_API_ORIGIN: api})));
});

test('production requires a distinct explicitly bound database, private buckets and exact service origins', () => {
  for (const override of [
    {DATABASE_URL: configured().DATABASE_URL.replace('sslmode=require', 'sslmode=disable')},
    {PRODUCTION_DATABASE_NAME: 'snaglist_test'}, {PRODUCTION_DATABASE_HOST: 'another.neon.tech'},
    {BASE_URL: 'https://staging-api.usesnaglist.com'}, {MAGIC_LINK_BASE_URL: portal},
    {PORTAL_ORIGIN: 'https://staging-app.usesnaglist.com'}, {R2_PRIVATE_BUCKET_NAME: 'snaglist-staging-private'},
    {R2_PUBLIC_URL: 'https://public.r2.dev'}, {R2_BUCKET_NAME: 'snaglist-staging-uploads'}
  ]) assert.throws(() => productionContainerEnvironment(configured(override)));
  for (const host of ['ep-bitter-wave-zacpbrh7.c-2.eu-west-2.aws.neon.tech',
                      'ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech']) {
    assert.throws(() => productionContainerEnvironment(configured({PRODUCTION_DATABASE_HOST: host,
      DATABASE_URL: `postgres://synthetic:synthetic@${host}/snaglist?sslmode=require`})));
  }
});

test('production import remains disabled unless its distinct switch and exact identity are supplied together', () => {
  assert.equal(productionContainerEnvironment(configured()).PRODUCTION_LEGACY_IMPORT_ENABLED, undefined);
  assert.equal(productionContainerEnvironment(configured({PRODUCTION_LEGACY_IMPORT_ENABLED: 'false'})).PRODUCTION_LEGACY_IMPORT_ENABLED, undefined);
  for (const override of [{PRODUCTION_LEGACY_IMPORT_ENABLED: 'true'}, {PRODUCTION_IMPORT_API_ORIGIN: api},
    {PRODUCTION_LEGACY_IMPORT_ENABLED: 'true', PRODUCTION_IMPORT_API_ORIGIN: 'https://staging-api.usesnaglist.com'}]) {
    assert.throws(() => productionContainerEnvironment(configured(override)));
  }
  const enabled = productionContainerEnvironment(configured({PRODUCTION_LEGACY_IMPORT_ENABLED: 'true', PRODUCTION_IMPORT_API_ORIGIN: api}));
  assert.equal(enabled.PRODUCTION_LEGACY_IMPORT_ENABLED, 'true');
  assert.equal(enabled.PRODUCTION_IMPORT_API_ORIGIN, api);
  assert.equal(enabled.STAGED_LEGACY_IMPORT_ENABLED, undefined);
});

test('production private media requires its pinned create-only namespace and cannot delete without it', () => {
  for (const override of [{R2_PRIVATE_NAMESPACE: undefined}, {R2_PRIVATE_NAMESPACE: ''},
    {R2_PRIVATE_NAMESPACE: 'private-v1'}, {R2_PRIVATE_NAMESPACE: 'private-v2/'},
    {R2_PRIVATE_NAMESPACE: 'immutable-v1/'}, {R2_PRIVATE_NAMESPACE: '../'},
    {R2_PRIVATE_NAMESPACE: undefined, ACCOUNT_DELETION_ENABLED: 'true'},
    {R2_PRIVATE_NAMESPACE: 'private-v2/', ACCOUNT_DELETION_ENABLED: 'true'},
    {ACCOUNT_DELETION_ENABLED: ''}, {ACCOUNT_DELETION_ENABLED: '1'}, {ACCOUNT_DELETION_ENABLED: 'TRUE'}
  ]) assert.throws(() => productionContainerEnvironment(configured(override)));
  const off = productionContainerEnvironment(configured());
  assert.equal(off.R2_PRIVATE_NAMESPACE, 'private-v1/');
  assert.equal(off.ACCOUNT_DELETION_ENABLED, 'false');
  assert.equal(productionContainerEnvironment(configured({ACCOUNT_DELETION_ENABLED: 'false'})).ACCOUNT_DELETION_ENABLED, 'false');
  const deleting = productionContainerEnvironment(configured({ACCOUNT_DELETION_ENABLED: 'true'}));
  assert.equal(deleting.ACCOUNT_DELETION_ENABLED, 'true');
  assert.equal(deleting.R2_PRIVATE_NAMESPACE, 'private-v1/');
});

test('production refuses partial identity, mail, purchase and encryption configuration', () => {
  for (const override of [
    {APPLE_CLIENT_ID: 'com.snaglist.app.staging'}, {APPLE_CREDENTIAL_KEY: configured().JWT_SECRET},
    {APPLE_PRIVATE_KEY: undefined}, {MAINTENANCE_SECRET: configured().JWT_SECRET},
    {GOOGLE_AUTH_ENVIRONMENT: 'staging'}, {GOOGLE_WEB_CLIENT_ID: configured().GOOGLE_IOS_CLIENT_ID},
    {RESEND_API_KEY: undefined}, {EMAIL_FROM: 'unverified@example.test'},
    {EMAIL_ALLOWED_RECIPIENTS: 'synthetic@example.test'}, {REVENUECAT_SECRET_API_KEY: undefined},
    {LINK_GRANT_TOKEN_PREVIOUS_KEY: configured().APPLE_CREDENTIAL_KEY}, {APNS_KEY_ID: 'partial'}
  ]) assert.throws(() => productionContainerEnvironment(configured(override)));
  const result = productionContainerEnvironment(configured({UNRELATED_SECRET: 'never-forward'}));
  assert.equal(result.PLATFORM_ENVIRONMENT, 'production');
  assert.equal(result.DATABASE_TLS_DISABLE, 'false');
  assert.equal(result.UNRELATED_SECRET, undefined);
  assert.equal(result.PRODUCTION_ENABLED, undefined);
});

test('production guard rejects all public maintenance spellings and unsafe legacy uploads before container access', async () => {
  let calls = 0;
  const env = {...configured(), BACKEND: {getByName() { calls++; throw new Error('must not run'); }}};
  for (const path of ['/internal/maintenance/cleanup', '/INTERNAL/maintenance/cleanup', '/%69nternal/maintenance/cleanup']) {
    assert.equal((await productionResponse(new Request(api + path), env)).status, 404);
  }
  for (const path of ['/api/v1/uploads/photo', '/api/v1/magic-links/synthetic/photos',
    '/api/v1/magic-links/synthetic/drawings', '/api/v1/magic-links/synthetic/report']) {
    assert.equal((await productionResponse(new Request(api + path, {method: 'POST'}), env)).status, 503);
  }
  assert.equal((await productionResponse(new Request('https://preview.example.test/api/v2/projects'), env)).status, 421);
  assert.equal(calls, 0);
});

test('production API and portal service binding preserve browser identity and never retry uncertain writes', async () => {
  let calls = 0;
  const env = {...configured(), BACKEND: {getByName(name) {
    assert.equal(name, 'production');
    return {async fetch(req) { calls++; assert.equal(req.headers.get('Origin'), portal);
      assert.equal(req.headers.get('X-CSRF-Token'), 'synthetic');
      throw new Error('private-token-must-not-appear'); }};
  }}};
  const reply = await productionResponse(new Request(portal + '/api/v2/projects', {method: 'POST',
    headers: {Origin: portal, 'X-CSRF-Token': 'synthetic'}}), env);
  assert.equal(reply.status, 503); assert.equal(calls, 1);
  assert.doesNotMatch(await reply.text(), /private-token/);
  assert.equal(reply.headers.get('Cache-Control'), 'no-store');
});

test('maintenance requires a recorded recent completion and bounded structured response', async () => {
  const now = Date.parse('2026-09-19T12:00:00Z');
  let body = {ran: true, removed: {}, lastSuccessfulRun: '2026-09-19T12:00:00Z'}, status = 200;
  const env = {...configured(), BACKEND: {getByName(name) {
    assert.equal(name, 'production');
    return {async fetch(req) {
      assert.equal(req.method, 'POST');
      assert.equal(new URL(req.url).pathname, '/internal/maintenance/cleanup');
      assert.equal(req.headers.get('Authorization'), 'Bearer ' + configured().MAINTENANCE_SECRET);
      return new Response(JSON.stringify(body), {status, headers: {'Content-Type': 'application/json'}});
    }};
  }}};
  await productionMaintenance(env, now);
  body.ran = false; await productionMaintenance(env, now);
  for (const candidate of [null, '2026-09-18T09:59:59Z', '2026-09-19T12:02:00Z', 'invalid']) {
    body.lastSuccessfulRun = candidate;
    await assert.rejects(productionMaintenance(env, now), /maintenance failed/);
  }
  body = {ran: true, lastSuccessfulRun: '2026-09-19T12:00:00Z', padding: 'a'.repeat(4096)};
  await assert.rejects(productionMaintenance(env, now), /maintenance failed/);
  body = {ran: true, lastSuccessfulRun: '2026-09-19T12:00:00Z'}; status = 503;
  await assert.rejects(productionMaintenance(env, now), /maintenance failed/);
});

test('push configuration requires the shipping team and base64 PEM expected by APNsService', () => {
  const pem = '-----BEGIN PRIVATE KEY-----\nU3ludGhldGlj\n-----END PRIVATE KEY-----';
  const push = {APNS_KEY_ID: 'SYNTHETIC3', APNS_TEAM_ID: '52ZZHYHM62', APNS_BUNDLE_ID: 'com.snaglist.app', APNS_ENVIRONMENT: 'production', APNS_PRIVATE_KEY: Buffer.from(pem).toString('base64')};
  assert.equal(productionContainerEnvironment(configured(push)).APNS_PRIVATE_KEY, push.APNS_PRIVATE_KEY);
  for (const override of [{APNS_PRIVATE_KEY: pem}, {APNS_PRIVATE_KEY: Buffer.from('not PEM').toString('base64')}, {APNS_TEAM_ID: 'SYNTHETIC4'}, {APNS_KEY_ID: 'short'}]) {
    assert.throws(() => productionContainerEnvironment(configured({...push, ...override})));
  }
  assert.throws(() => productionContainerEnvironment(configured({APPLE_TEAM_ID: 'SYNTHETIC4'})));
});

test('portal deployment routes all static requests through the disabled-by-default Worker guard', () => {
  const source = readFileSync(new URL('../wrangler.portal-production.jsonc', import.meta.url), 'utf8');
  const config = JSON.parse(source.replace(/^\s*\/\/.*$/gm, ''));
  assert.equal(config.assets.binding, 'ASSETS');
  assert.equal(config.assets.run_worker_first, true);
  assert.equal(config.vars.PRODUCTION_PORTAL_ENABLED, 'false');
  assert.equal(config.workers_dev, false);
  assert.equal(config.routes, undefined);
});

test('production portal requires its own enablement and never serves staging, preview or private route SPA fallbacks', async () => {
  const env = {PRODUCTION_PORTAL_ENABLED: 'true', PORTAL_ORIGIN: portal,
    BACKEND: {fetch: async () => new Response('api')}, ASSETS: {fetch: async () => new Response('spa')}};
  assert.equal(await (await productionPortalResponse(new Request(portal + '/projects'), env)).text(), 'spa');
  assert.equal(await (await productionPortalResponse(new Request(portal + '/api/v2/account'), env)).text(), 'api');
  assert.equal((await portalResponse(new Request(portal), env)).status, 503);
  assert.equal((await productionPortalResponse(new Request(portal), {...env, STAGING_PORTAL_ENABLED: 'false'})).status, 503);
  assert.equal((await productionPortalResponse(new Request('https://staging-app.usesnaglist.com'), env)).status, 421);
  for (const path of ['/m/c2_synthetic', '/internal/maintenance/cleanup', '/api/v1/users/me']) {
    assert.equal((await productionPortalResponse(new Request(portal + path), env)).status, 404);
  }
});
