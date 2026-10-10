import test from 'node:test';
import assert from 'node:assert/strict';
import {backendInstance, containerEnvironment} from '../src/config.mjs';

const sample = () => ({
  STAGING_ENABLED: 'true', STAGING_DATABASE_HOST: 'staging-db.example.com',
  DATABASE_URL: 'postgresql://synthetic:synthetic@staging-db.example.com/snaglist_staging?sslmode=require',
  JWT_SECRET: 'synthetic-only-secret-at-least-32-characters',
  BASE_URL: 'https://snaglist-api-staging.danielmccann1705.workers.dev',
  MAGIC_LINK_BASE_URL: 'https://snaglist-api-staging.danielmccann1705.workers.dev',
  R2_ACCOUNT_ID: 'test-account', R2_BUCKET_NAME: 'snaglist-staging-uploads',
  R2_PUBLIC_URL: 'https://staging-photos.example.com',
  R2_ACCESS_KEY_ID: 'synthetic', R2_SECRET_ACCESS_KEY: 'synthetic'
});

test('stage is closed by default', () => {
  assert.throws(() => containerEnvironment({}));
  assert.throws(() => containerEnvironment({...sample(), STAGING_ENABLED: 'false'}));
});
test('missing secrets cannot fall back to ephemeral photo storage', () => {
  for (const key of ['DATABASE_URL','JWT_SECRET','R2_ACCESS_KEY_ID','R2_SECRET_ACCESS_KEY','R2_PUBLIC_URL']) {
    const env=sample(); delete env[key]; assert.throws(() => containerEnvironment(env));
  }
});
test('production photo storage and production links are rejected', () => {
  for (const override of [{R2_BUCKET_NAME:'snaglist-uploads'},
    {R2_PUBLIC_URL:'https://cdn.snaglist.dev'}, {BASE_URL:'https://snaglist.dev'},
    {MAGIC_LINK_BASE_URL:'https://snaglist.dev'}]) {
    assert.throws(() => containerEnvironment({...sample(), ...override}));
  }
});
test('database must match the selected staging host and require TLS', () => {
  for (const url of ['postgresql://a:b@production.example.com/db?sslmode=require',
    'postgresql://a:b@staging-db.example.com/db?sslmode=disable',
    'postgresql://staging-db.example.com/db?sslmode=require']) {
    assert.throws(() => containerEnvironment({...sample(), DATABASE_URL:url}));
  }
});
test('a trailing media-origin slash cannot create broken double-slash photo URLs', () => {
  const env=containerEnvironment({...sample(),R2_PUBLIC_URL:'https://staging-photos.example.com/'});
  assert.equal(env.R2_PUBLIC_URL+'/uploads/synthetic.jpg',
    'https://staging-photos.example.com/uploads/synthetic.jpg');
});
test('staging refuses unapproved provider credentials and passes only declared settings', () => {
  for (const key of ['RESEND_API_KEY','REVENUECAT_SECRET_API_KEY','APNS_PRIVATE_KEY']) {
    assert.throws(() => containerEnvironment({...sample(),[key]:'do-not-send'}));
  }
  const env=containerEnvironment({...sample(), UNRELATED_SECRET:'must-not-pass'});
  assert.equal(env.DATABASE_TLS_DISABLE,'false');
  assert.equal(env.R2_BUCKET_NAME,'snaglist-staging-uploads');
  assert.equal(env.UNRELATED_SECRET,undefined);
});

test('staging email can only reach the approved test mailbox', () => {
  const email = {RESEND_API_KEY:'synthetic',STAGING_EMAIL_ENABLED:'true',
    EMAIL_ALLOWED_RECIPIENTS:'danielmccann1705@gmail.com',
    EMAIL_FROM:'Snaglist <notifications@mail.snaglist.dev>'};
  assert.equal(containerEnvironment({...sample(),...email}).EMAIL_ALLOWED_RECIPIENTS,
    'danielmccann1705@gmail.com');
  for (const override of [{STAGING_EMAIL_ENABLED:'false'},
    {EMAIL_ALLOWED_RECIPIENTS:'customer@example.com'},
    {EMAIL_ALLOWED_RECIPIENTS:'danielmccann1705@gmail.com,customer@example.com'},
    {EMAIL_FROM:'Snaglist <notifications@unverified.example>'}]) {
    assert.throws(()=>containerEnvironment({...sample(),...email,...override}));
  }
});

// All values below are synthetic, not deployment secrets/provider registrations.
const platform = () => ({STAGING_PLATFORM_ENABLED:'true', PLATFORM_ENVIRONMENT:'staging',
  PORTAL_ORIGIN:'https://staging-app.usesnaglist.com', R2_PRIVATE_BUCKET_NAME:'snaglist-staging-private',
  LINK_GRANT_TOKEN_KEY: btoa('s'.repeat(32))});
const google = () => ({GOOGLE_AUTH_ENVIRONMENT:'staging',
  GOOGLE_WEB_CLIENT_ID:'1234-webtest.apps.googleusercontent.com',
  GOOGLE_IOS_CLIENT_ID:'1234-iostest.apps.googleusercontent.com'});

test('explicit unified staging forwards the required private media, browser and link settings', () => {
  const env=containerEnvironment({...sample(),...platform(),...google(),UNRELATED_SECRET:'never-forward'});
  for (const [key,value] of Object.entries({...platform(),...google()})) {
    if (key !== 'STAGING_PLATFORM_ENABLED') assert.equal(env[key],value);
  }
  assert.equal(env.UNRELATED_SECRET,undefined);
  assert.equal(env.STAGING_PLATFORM_ENABLED,undefined);
  assert.equal(env.BASE_URL,sample().BASE_URL,'Recovery link origins do not silently move');
});

test('partial or disabled platform configuration fails closed', () => {
  for (const key of ['PLATFORM_ENVIRONMENT','PORTAL_ORIGIN','R2_PRIVATE_BUCKET_NAME','LINK_GRANT_TOKEN_KEY']) {
    const env={...sample(),...platform()}; delete env[key];
    assert.throws(() => containerEnvironment(env));
  }
  for (const flag of [undefined,'false','1']) {
    assert.throws(() => containerEnvironment({...sample(),...platform(),STAGING_PLATFORM_ENABLED:flag}));
  }
  assert.throws(() => containerEnvironment({...sample(),...google()}));
  const recovery=containerEnvironment(sample());
  assert.equal(recovery.PORTAL_ORIGIN,undefined);
  assert.equal(recovery.LINK_GRANT_TOKEN_KEY,undefined);
});

test('staging platform rejects production, local and misleading origins/storage', () => {
  for (const origin of ['https://app.usesnaglist.com','http://staging-app.usesnaglist.com',
    'https://staging-app.usesnaglist.com/','https://staging-app.usesnaglist.com.evil.test',
    'https://staging-app.usesnaglist.com?x=1','https://user@staging-app.usesnaglist.com']) {
    assert.throws(() => containerEnvironment({...sample(),...platform(),PORTAL_ORIGIN:origin}));
  }
  for (const override of [{PLATFORM_ENVIRONMENT:'production'}, {PLATFORM_ENVIRONMENT:'local'},
    {R2_PRIVATE_BUCKET_NAME:'snaglist-staging-uploads'}, {R2_PRIVATE_BUCKET_NAME:'snaglist-private'}]) {
    assert.throws(() => containerEnvironment({...sample(),...platform(),...override}));
  }
});

test('capability keys are validated without echoing their contents and rotation is explicit', () => {
  for (const bad of [undefined,'','invalid-secret-do-not-echo',btoa('short'),btoa('x'.repeat(33)),
    platform().LINK_GRANT_TOKEN_KEY.replace(/=$/, 'A')]) {
    assert.throws(() => containerEnvironment({...sample(),...platform(),LINK_GRANT_TOKEN_KEY:bad}),
      error => !error.message.includes('invalid-secret-do-not-echo'));
  }
  assert.throws(() => containerEnvironment({...sample(),...platform(),JWT_SECRET:platform().LINK_GRANT_TOKEN_KEY}));
  for (const bad of ['', 'invalid', platform().LINK_GRANT_TOKEN_KEY]) {
    assert.throws(() => containerEnvironment({...sample(),...platform(),LINK_GRANT_TOKEN_PREVIOUS_KEY:bad}));
  }
  // Fixed-length synthetic bytes represent the separately retained rotation key.
  const previous=btoa('p'.repeat(32));
  assert.equal(containerEnvironment({...sample(),...platform(),LINK_GRANT_TOKEN_PREVIOUS_KEY:previous})
    .LINK_GRANT_TOKEN_PREVIOUS_KEY,previous);
});

test('Google stays unavailable unless both distinct staging client IDs are provided', () => {
  const core=containerEnvironment({...sample(),...platform()});
  assert.equal(core.GOOGLE_WEB_CLIENT_ID,undefined);
  for (const key of Object.keys(google())) {
    const env={...sample(),...platform(),...google()}; delete env[key];
    assert.throws(() => containerEnvironment(env));
  }
  for (const override of [{GOOGLE_AUTH_ENVIRONMENT:'production'},
    {GOOGLE_IOS_CLIENT_ID:google().GOOGLE_WEB_CLIENT_ID},
    {GOOGLE_WEB_CLIENT_ID:'https://accounts.google.com'},
    {GOOGLE_WEB_CLIENT_ID:'1234-synthetic.apps.googleusercontent.com.evil.test'}]) {
    assert.throws(() => containerEnvironment({...sample(),...platform(),...google(),...override}));
  }
});

const candidate = () => ({...sample(),...platform(),STAGING_DEPLOYMENT:'unified-candidate',
  STAGING_DATABASE_HOST:'ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech',
  DATABASE_URL:'postgresql://synthetic:synthetic@ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech/snaglist_platform_test_0910222943_fc44?sslmode=require',
  BASE_URL:'https://snaglist-api-unified-staging.danielmccann1705.workers.dev',
  MAGIC_LINK_BASE_URL:'https://snaglist-api-unified-staging.danielmccann1705.workers.dev',
  R2_ACCOUNT_ID:'387d49014cd0d45f9e6434196ab513c0', R2_BUCKET_NAME:'snaglist-unified-staging-uploads',
  R2_PUBLIC_URL:'https://pub-d7c456d4b396462fb5ee8ef008dcf93b.r2.dev'});
const importOptIn = () => ({STAGED_LEGACY_IMPORT_ENABLED:'true',
  IMPORT_PREVIEW_API_ORIGIN:'https://snaglist-api-unified-staging.danielmccann1705.workers.dev'});

// Sign in with Apple. Synthetic identifiers and key material only; the audience is
// the staging bundle, the exchange is the team credential the container signs its
// client secrets with, and the web trio is the staging Services ID beside that bundle.
const appleAudience = () => ({APPLE_BUNDLE_ID:'com.snaglist.app.staging', APPLE_CLIENT_ID:'com.snaglist.app.staging'});
const appleExchange = () => ({APPLE_TEAM_ID:'SYNTHETIC1', APPLE_KEY_ID:'SYNTHETIC2',
  APPLE_PRIVATE_KEY:'-----BEGIN PRIVATE KEY----- synthetic only', APPLE_CREDENTIAL_KEY: btoa('a'.repeat(32))});
const appleWeb = () => ({APPLE_WEB_ENABLED:'true', APPLE_WEB_AUTH_ENVIRONMENT:'staging',
  APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging.web'});
const appleWebNames = Object.keys(appleWeb());

test('staging Apple audience and token exchange install only for the enabled candidate, each all-or-nothing', () => {
  const none = containerEnvironment(candidate());
  for (const key of [...Object.keys(appleAudience()), ...Object.keys(appleExchange()), ...appleWebNames]) {
    assert.equal(none[key], undefined);
  }
  const audience = containerEnvironment({...candidate(), ...appleAudience()});
  assert.equal(audience.APPLE_CLIENT_ID, 'com.snaglist.app.staging');
  assert.equal(audience.APPLE_TEAM_ID, undefined);
  const exchange = containerEnvironment({...candidate(), ...appleAudience(), ...appleExchange()});
  for (const [key, value] of Object.entries({...appleAudience(), ...appleExchange()})) assert.equal(exchange[key], value);
  for (const override of [{APPLE_CLIENT_ID:'com.snaglist.app'}, {APPLE_BUNDLE_ID:'com.snaglist.app'},
    {APPLE_CLIENT_ID:undefined}, {APPLE_BUNDLE_ID:undefined}]) {
    assert.throws(() => containerEnvironment({...candidate(), ...appleAudience(), ...override}));
  }
  for (const key of Object.keys(appleExchange())) {
    const env = {...candidate(), ...appleAudience(), ...appleExchange()}; delete env[key];
    assert.throws(() => containerEnvironment(env), `${key} missing must fail closed`);
  }
  assert.throws(() => containerEnvironment({...candidate(), ...appleAudience(), ...appleExchange(), APPLE_CREDENTIAL_KEY: platform().LINK_GRANT_TOKEN_KEY}));
  // The recovery deployment and a platform-disabled candidate accept no Apple configuration.
  assert.throws(() => containerEnvironment({...sample(), ...appleAudience()}));
  assert.throws(() => containerEnvironment({...sample(), ...platform(), ...appleAudience()}));
  assert.throws(() => containerEnvironment({...candidate(), STAGING_PLATFORM_ENABLED:'false', ...appleAudience()}));
});

test('staging Apple web sign-in needs its exact Services ID, the switch and the token exchange together', () => {
  const on = containerEnvironment({...candidate(), ...appleAudience(), ...appleExchange(), ...appleWeb()});
  assert.deepEqual(Object.fromEntries(appleWebNames.map(name => [name, on[name]])), appleWeb());
  assert.equal(on.APPLE_CLIENT_ID, 'com.snaglist.app.staging', 'a Services ID never replaces the bundle audience');
  assert.equal(on.APPLE_BUNDLE_ID, 'com.snaglist.app.staging');
  // Turning the web flow on moves nothing else.
  const off = containerEnvironment({...candidate(), ...appleAudience(), ...appleExchange()});
  assert.deepEqual({...on, APPLE_WEB_ENABLED:null, APPLE_WEB_AUTH_ENVIRONMENT:null, APPLE_WEB_CLIENT_ID:null},
                   {...off, APPLE_WEB_ENABLED:null, APPLE_WEB_AUTH_ENVIRONMENT:null, APPLE_WEB_CLIENT_ID:null});
  // Written-down off forwards nothing and needs nothing else.
  for (const env of [candidate(), {...candidate(), ...appleAudience()}, sample(), {...sample(), ...platform()}]) {
    const result = containerEnvironment({...env, APPLE_WEB_ENABLED:'false'});
    for (const name of appleWebNames) assert.equal(result[name], undefined);
  }
  const base = {...candidate(), ...appleAudience(), ...appleExchange()};
  for (const override of [
    // Switch without identity, identity without switch, every one-of-three.
    {APPLE_WEB_ENABLED:'true'}, {APPLE_WEB_ENABLED:'true', APPLE_WEB_AUTH_ENVIRONMENT:'staging'},
    {APPLE_WEB_ENABLED:'true', APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging.web'},
    {APPLE_WEB_AUTH_ENVIRONMENT:'staging', APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging.web'},
    {APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging.web'}, {APPLE_WEB_AUTH_ENVIRONMENT:'staging'},
    {APPLE_WEB_ENABLED:'false', APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging.web'},
    {APPLE_WEB_ENABLED:'false', APPLE_WEB_AUTH_ENVIRONMENT:'staging'},
    {...appleWeb(), APPLE_WEB_ENABLED:'false'},
    // Exact literals only.
    {...appleWeb(), APPLE_WEB_ENABLED:'1'}, {...appleWeb(), APPLE_WEB_ENABLED:'TRUE'}, {...appleWeb(), APPLE_WEB_ENABLED:''},
    {APPLE_WEB_ENABLED:''}, {APPLE_WEB_ENABLED:'yes'},
    // Staging's own environment and the staging Services ID, nothing else.
    {...appleWeb(), APPLE_WEB_AUTH_ENVIRONMENT:'production'}, {...appleWeb(), APPLE_WEB_AUTH_ENVIRONMENT:'local'},
    {...appleWeb(), APPLE_WEB_CLIENT_ID:'com.snaglist.app.web'}, {...appleWeb(), APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging'},
    {...appleWeb(), APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging.web.evil'}, {...appleWeb(), APPLE_WEB_CLIENT_ID:''},
    // The Services ID may not take the bundle's place.
    {...appleWeb(), APPLE_CLIENT_ID:'com.snaglist.app.staging.web'},
    {...appleWeb(), APPLE_BUNDLE_ID:'com.snaglist.app.staging.web', APPLE_CLIENT_ID:'com.snaglist.app.staging.web'}
  ]) {
    assert.throws(() => containerEnvironment({...base, ...override}), JSON.stringify(override));
  }
  // Web without the exchange, without the audience, or outside the enabled candidate.
  assert.throws(() => containerEnvironment({...candidate(), ...appleAudience(), ...appleWeb()}), 'web needs the exchange');
  assert.throws(() => containerEnvironment({...candidate(), ...appleExchange(), ...appleWeb()}), 'web needs the audience');
  assert.throws(() => containerEnvironment({...candidate(), ...appleWeb()}), 'web alone');
  assert.throws(() => containerEnvironment({...sample(), ...platform(), ...appleAudience(), ...appleExchange(), ...appleWeb()}), 'recovery deployment');
  assert.throws(() => containerEnvironment({...base, ...appleWeb(), STAGING_PLATFORM_ENABLED:'false'}), 'platform disabled');
});

test('legacy import preparation stays off unless the enabled candidate opts in on its own origin', () => {
  const off=containerEnvironment(candidate());
  assert.equal(off.STAGED_LEGACY_IMPORT_ENABLED,undefined);
  assert.equal(off.IMPORT_PREVIEW_API_ORIGIN,undefined);
  const on=containerEnvironment({...candidate(),...importOptIn()});
  assert.equal(on.STAGED_LEGACY_IMPORT_ENABLED,'true');
  assert.equal(on.IMPORT_PREVIEW_API_ORIGIN,importOptIn().IMPORT_PREVIEW_API_ORIGIN);
  for (const override of [{STAGED_LEGACY_IMPORT_ENABLED:'1'},{STAGED_LEGACY_IMPORT_ENABLED:'false'},
    {IMPORT_PREVIEW_API_ORIGIN:undefined},{IMPORT_PREVIEW_API_ORIGIN:'https://snaglist-api-staging.danielmccann1705.workers.dev'},
    {IMPORT_PREVIEW_API_ORIGIN:'https://api.snaglist.dev'}]) {
    assert.throws(() => containerEnvironment({...candidate(),...importOptIn(),...override}));
  }
  assert.throws(() => containerEnvironment({...sample(),...platform(),...importOptIn()}),'the recovery deployment cannot opt in');
  assert.throws(() => containerEnvironment({...candidate(),STAGED_LEGACY_IMPORT_ENABLED:'true'}),'half-supplied opt-in fails closed');
});

test('private media and account deletion install only for the candidate that can fence', () => {
  const off=containerEnvironment(candidate());
  assert.equal(off.R2_PRIVATE_NAMESPACE,undefined);
  assert.equal(off.ACCOUNT_DELETION_ENABLED,undefined);
  const fenced=containerEnvironment({...candidate(),R2_PRIVATE_NAMESPACE:'private-v1/'});
  assert.equal(fenced.R2_PRIVATE_NAMESPACE,'private-v1/');
  assert.equal(fenced.ACCOUNT_DELETION_ENABLED,'false');
  const deleting=containerEnvironment({...candidate(),R2_PRIVATE_NAMESPACE:'private-v1/',ACCOUNT_DELETION_ENABLED:'true'});
  assert.equal(deleting.R2_PRIVATE_NAMESPACE,'private-v1/');
  assert.equal(deleting.ACCOUNT_DELETION_ENABLED,'true');
  for (const override of [{ACCOUNT_DELETION_ENABLED:'true'},{ACCOUNT_DELETION_ENABLED:'false'},
    {R2_PRIVATE_NAMESPACE:'private-v1'},{R2_PRIVATE_NAMESPACE:'private-v2/'},
    {R2_PRIVATE_NAMESPACE:''},{R2_PRIVATE_NAMESPACE:'../'},
    {R2_PRIVATE_NAMESPACE:'private-v1/',ACCOUNT_DELETION_ENABLED:'1'},
    {R2_PRIVATE_NAMESPACE:'private-v1/',ACCOUNT_DELETION_ENABLED:''}]) {
    assert.throws(() => containerEnvironment({...candidate(),...override}));
  }
  // The recovery deployment has no fenced private storage and may carry neither switch.
  for (const override of [{R2_PRIVATE_NAMESPACE:'private-v1/'},{ACCOUNT_DELETION_ENABLED:'true'},
    {R2_PRIVATE_NAMESPACE:'private-v1/',ACCOUNT_DELETION_ENABLED:'true'}]) {
    assert.throws(() => containerEnvironment({...sample(),...platform(),...override}));
    assert.throws(() => containerEnvironment({...sample(),...override}));
  }
});

test('the container log stream is optional, is one of two words, and defaults to nothing at all', () => {
  // Absent is today's behaviour: the container is told nothing and logs where it always has.
  assert.equal(containerEnvironment(sample()).LOG_STREAM, undefined);
  assert.equal(containerEnvironment({...sample(), LOG_STREAM: 'stdout'}).LOG_STREAM, 'stdout');
  assert.equal(containerEnvironment({...sample(), LOG_STREAM: 'stderr'}).LOG_STREAM, 'stderr');
  for (const value of ['STDOUT', 'stderr ', '2', 'both', '', 'stdout,stderr', '/dev/stderr']) {
    assert.throws(() => containerEnvironment({...sample(), LOG_STREAM: value}));
  }
});

test('the log-stream probe marker is optional and cannot carry a secret', () => {
  assert.equal(containerEnvironment(sample()).LOG_STREAM_PROBE, undefined);
  for (const marker of ['SNAG0921A', 'A1B2C3D4', 'STREAM-0921-A', 'X'.repeat(48)]) {
    assert.equal(containerEnvironment({...sample(), LOG_STREAM_PROBE: marker}).LOG_STREAM_PROBE, marker);
  }
  // Too short, too long, edged with a hyphen, or outside the alphabet. The last four are the
  // point of the alphabet: a base64 key, a bearer, a cookie value and a Contractor link token
  // all carry lowercase or one of + / = and so none of them can be routed into a log line here.
  for (const marker of ['SHORT7', 'Y'.repeat(49), '-SNAG0921', 'SNAG0921-', 'SNAG 0921',
    'c25hZ2xpc3Qtc3ludGhldGlj', 'Bearer-abc123', 'sid=0123456789abcdef', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=']) {
    assert.throws(() => containerEnvironment({...sample(), LOG_STREAM_PROBE: marker}));
  }
});

test('the database pool size is optional, a whole number from 1 to 16, and absent means the old pool', () => {
  assert.equal(containerEnvironment(sample()).DATABASE_MAX_CONNECTIONS, undefined);
  for (const [value, expected] of [['1', '1'], ['4', '4'], ['16', '16'], [4, '4'], [16, '16']]) {
    assert.equal(containerEnvironment({...sample(), DATABASE_MAX_CONNECTIONS: value}).DATABASE_MAX_CONNECTIONS, expected);
  }
  for (const value of ['0', '17', '04', '4 ', '-1', '1.5', 'four', '', 0, 17, 2.5, true, null]) {
    assert.throws(() => containerEnvironment({...sample(), DATABASE_MAX_CONNECTIONS: value}));
  }
});

test('staging runtime diagnostics are absent unless exactly "enabled"', () => {
  assert.equal(containerEnvironment(sample()).RUNTIME_DIAGNOSTICS, undefined);
  assert.equal(containerEnvironment({...sample(), RUNTIME_DIAGNOSTICS: 'enabled'}).RUNTIME_DIAGNOSTICS, 'enabled');
  for (const value of ['true', 'Enabled', 'enabled ', '1', '', 'on']) {
    assert.throws(() => containerEnvironment({...sample(), RUNTIME_DIAGNOSTICS: value}));
  }
});

test('the staging Durable Object name is "staging" unless another staging name is chosen', () => {
  assert.equal(backendInstance({}), 'staging');
  assert.equal(backendInstance(sample()), 'staging');
  for (const name of ['staging', 'staging-lhr', 'staging-weur2', 'staging-a-b', 'staging-' + 'x'.repeat(16)]) {
    assert.equal(backendInstance({BACKEND_INSTANCE: name}), name);
  }
  // Never a production name, an empty or padded value, upper case, another shape or a non-string.
  for (const name of ['production', '', ' staging', 'staging ', 'Staging', 'staging-', 'staging--a', 'staging-LHR',
    'staging-a-b-c', 'staging-' + 'x'.repeat(17), 'staging_lhr', 'staging/lhr', 'stagingx', 1, null, true]) {
    assert.throws(() => backendInstance({BACKEND_INSTANCE: name}));
  }
  // The container's environment never carries it: it names the object, not a setting of the app.
  assert.equal(containerEnvironment({...sample(), BACKEND_INSTANCE: 'staging-lhr'}).BACKEND_INSTANCE, undefined);
});

// Replacement 2.0.1 measurement (9 Oct 2026). Synthetic values only.
const measurement = () => ({FEATURE_PRODUCT_ANALYTICS_ENABLED:'true', POSTHOG_MEASUREMENT_ENVIRONMENT:'sandbox',
  POSTHOG_PROJECT_API_KEY:'phc_synthetic0000000000000000000000',
  MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY: btoa('h'.repeat(32)), MEASUREMENT_PURCHASE_ORIGIN_ENVIRONMENT:'sandbox'});
const measurementKeys = ['FEATURE_PRODUCT_ANALYTICS_ENABLED','POSTHOG_MEASUREMENT_ENVIRONMENT','POSTHOG_PROJECT_API_KEY',
  'MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY','MEASUREMENT_PURCHASE_ORIGIN_ENVIRONMENT','REVENUECAT_WEBHOOK_AUTHORIZATION',
  'REVENUECAT_APP_ID','FEATURE_CROSS_COMPANY_ADS_ENABLED','FEATURE_LINKEDIN_CONVERSIONS_ENABLED','FEATURE_AD_MEASUREMENT_ENABLED'];

test('measurement absent: the candidate forwards no measurement setting at all', () => {
  const env=containerEnvironment(candidate());
  for (const key of measurementKeys) assert.equal(env[key],undefined,key);
});

test('measurement forwards only the sandbox product analytics, purchase-origin and optional RevenueCat settings', () => {
  const webhook={REVENUECAT_WEBHOOK_AUTHORIZATION:'Bearer synthetic-webhook-value-0000000000', REVENUECAT_APP_ID:'appsynthetic01'};
  const env=containerEnvironment({...candidate(),...measurement(),...webhook,
    FEATURE_CROSS_COMPANY_ADS_ENABLED:'false', FEATURE_LINKEDIN_CONVERSIONS_ENABLED:'false', FEATURE_AD_MEASUREMENT_ENABLED:'false'});
  for (const [key,value] of Object.entries({...measurement(),...webhook})) assert.equal(env[key],value,key);
  for (const key of ['FEATURE_CROSS_COMPANY_ADS_ENABLED','FEATURE_LINKEDIN_CONVERSIONS_ENABLED','FEATURE_AD_MEASUREMENT_ENABLED']) {
    assert.equal(env[key],'false',key);
  }
  const productOnly=containerEnvironment({...candidate(),FEATURE_PRODUCT_ANALYTICS_ENABLED:'false',
    POSTHOG_MEASUREMENT_ENVIRONMENT:'sandbox',POSTHOG_PROJECT_API_KEY:measurement().POSTHOG_PROJECT_API_KEY});
  assert.equal(productOnly.FEATURE_PRODUCT_ANALYTICS_ENABLED,'false');
  assert.equal(productOnly.MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY,undefined);
  assert.equal(productOnly.REVENUECAT_WEBHOOK_AUTHORIZATION,undefined);
});

test('the privacy-choices capability is absent (off), "true" or "false", and "true" only on the enabled candidate', () => {
  assert.equal(containerEnvironment(candidate()).FEATURE_MEASUREMENT_CHOICES_ENABLED, undefined);
  for (const value of ['true','false']) {
    assert.equal(containerEnvironment({...candidate(),FEATURE_MEASUREMENT_CHOICES_ENABLED:value}).FEATURE_MEASUREMENT_CHOICES_ENABLED, value);
    assert.equal(containerEnvironment({...candidate(),...measurement(),FEATURE_MEASUREMENT_CHOICES_ENABLED:value})
      .FEATURE_MEASUREMENT_CHOICES_ENABLED, value);
  }
  for (const value of ['yes','TRUE','1','']) {
    assert.throws(() => containerEnvironment({...candidate(),FEATURE_MEASUREMENT_CHOICES_ENABLED:value}));
  }
  assert.throws(() => containerEnvironment({...sample(),FEATURE_MEASUREMENT_CHOICES_ENABLED:'true'}));
  assert.throws(() => containerEnvironment({...sample(),...platform(),FEATURE_MEASUREMENT_CHOICES_ENABLED:'true'}));
  assert.equal(containerEnvironment({...sample(),FEATURE_MEASUREMENT_CHOICES_ENABLED:'false'}).FEATURE_MEASUREMENT_CHOICES_ENABLED, 'false');
});

test('measurement cannot reach production, advertising or provider erasure from staging', () => {
  for (const override of [{POSTHOG_MEASUREMENT_ENVIRONMENT:'production'}, {POSTHOG_MEASUREMENT_ENVIRONMENT:undefined},
    {POSTHOG_PROJECT_API_KEY:'phx_personal_key_do_not_echo_000000000'}, {POSTHOG_PROJECT_API_KEY:undefined},
    {FEATURE_PRODUCT_ANALYTICS_ENABLED:'yes'}, {FEATURE_PRODUCT_ANALYTICS_ENABLED:undefined},
    {MEASUREMENT_PURCHASE_ORIGIN_ENVIRONMENT:'production'}, {MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY:'short'},
    {MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY:undefined}, {MEASUREMENT_PURCHASE_ORIGIN_HMAC_KEY: platform().LINK_GRANT_TOKEN_KEY},
    {REVENUECAT_WEBHOOK_AUTHORIZATION:'Bearer synthetic-webhook-value-0000000000'},
    {REVENUECAT_WEBHOOK_AUTHORIZATION:'synthetic-webhook-value-0000000000', REVENUECAT_APP_ID:'appsynthetic01'},
    {FEATURE_CROSS_COMPANY_ADS_ENABLED:'true'}, {FEATURE_LINKEDIN_CONVERSIONS_ENABLED:'true'},
    {FEATURE_AD_MEASUREMENT_ENABLED:'true'}, {POSTHOG_ERASURE_API_KEY:'synthetic'}, {POSTHOG_ERASURE_PROJECT_ID:'298161'},
    {LINKEDIN_CONVERSIONS_ACCESS_TOKEN:'synthetic'}, {SINGULAR_API_KEY:'synthetic'}, {SINGULAR_SERVER_EVENT_URL:'https://example.test'},
    {APPLE_ADSERVICES_OWNED_ORG_ID:'1'}, {MEASUREMENT_CREDENTIAL_KEY: btoa('c'.repeat(32))}]) {
    const env={...candidate(),...measurement(),...override};
    for (const [key,value] of Object.entries(override)) if (value === undefined) delete env[key];
    assert.throws(() => containerEnvironment(env), error => !error.message.includes('do_not_echo'), JSON.stringify(Object.keys(override)));
  }
  // The recovery image and a disabled platform never accept measurement settings.
  assert.throws(() => containerEnvironment({...sample(),...measurement()}));
  assert.throws(() => containerEnvironment({...sample(),...platform(),...measurement()}));
});

// Synthetic LinkedIn conversions to ONE isolated test rule (10 Oct 2026). Synthetic values only.
const linkedInTest = () => ({LINKEDIN_TEST_CONVERSION_RULE_ID:'987654321', FEATURE_LINKEDIN_CONVERSIONS_ENABLED:'true',
  FEATURE_CROSS_COMPANY_ADS_ENABLED:'true', LINKEDIN_CONVERSIONS_ACCESS_TOKEN:'synthetic-linkedin-token-do_not_echo-0000'});

test('one isolated LinkedIn test rule turns LinkedIn and cross-company on together, on the enabled candidate only', () => {
  const env=containerEnvironment({...candidate(),...measurement(),...linkedInTest()});
  assert.equal(env.FEATURE_LINKEDIN_CONVERSIONS_ENABLED,'true');
  assert.equal(env.FEATURE_CROSS_COMPANY_ADS_ENABLED,'true');
  assert.equal(env.LINKEDIN_CONVERSIONS_ACCESS_TOKEN,linkedInTest().LINKEDIN_CONVERSIONS_ACCESS_TOKEN);
  // The one rule is both rules: every staging LinkedIn conversion reaches it, and no other rule exists.
  assert.equal(env.LINKEDIN_SIGNUP_CONVERSION_RULE_ID,'987654321');
  assert.equal(env.LINKEDIN_SUBSCRIPTION_CONVERSION_RULE_ID,'987654321');
  assert.equal(env.LINKEDIN_TEST_CONVERSION_RULE_ID,undefined);
  assert.equal(env.PLATFORM_ENVIRONMENT,'staging', 'the backend derives its LinkedIn environment (sandbox) from this');
  assert.equal(env.LINKEDIN_ERASURE_RESOLUTION_ACCEPTED,undefined);
  // It needs no product-analytics configuration, and Apple Ads stays off.
  const alone=containerEnvironment({...candidate(),...linkedInTest(),FEATURE_AD_MEASUREMENT_ENABLED:'false'});
  assert.equal(alone.LINKEDIN_SIGNUP_CONVERSION_RULE_ID,'987654321');
  assert.equal(alone.FEATURE_AD_MEASUREMENT_ENABLED,'false');
  assert.equal(alone.POSTHOG_PROJECT_API_KEY,undefined);
  for (const override of [
    {FEATURE_LINKEDIN_CONVERSIONS_ENABLED:'false'}, {FEATURE_LINKEDIN_CONVERSIONS_ENABLED:undefined},
    {FEATURE_CROSS_COMPANY_ADS_ENABLED:'false'}, {FEATURE_CROSS_COMPANY_ADS_ENABLED:undefined},
    {LINKEDIN_TEST_CONVERSION_RULE_ID:'31231706'}, {LINKEDIN_TEST_CONVERSION_RULE_ID:'31231714'},
    {LINKEDIN_TEST_CONVERSION_RULE_ID:'0123'}, {LINKEDIN_TEST_CONVERSION_RULE_ID:'12a4'}, {LINKEDIN_TEST_CONVERSION_RULE_ID:''},
    {LINKEDIN_TEST_CONVERSION_RULE_ID:'1'.repeat(21)}, {LINKEDIN_TEST_CONVERSION_RULE_ID:'123,456'},
    {LINKEDIN_CONVERSIONS_ACCESS_TOKEN:undefined}, {LINKEDIN_CONVERSIONS_ACCESS_TOKEN:'short'},
    {LINKEDIN_CONVERSIONS_ACCESS_TOKEN:'has a space do_not_echo 000000'}, {LINKEDIN_CONVERSIONS_ACCESS_TOKEN: candidate().JWT_SECRET},
    {LINKEDIN_SIGNUP_CONVERSION_RULE_ID:'987654321'}, {LINKEDIN_SUBSCRIPTION_CONVERSION_RULE_ID:'987654321'},
    {LINKEDIN_ERASURE_RESOLUTION_ACCEPTED:'linkedin-erasure-2026-10-10'},
    {FEATURE_AD_MEASUREMENT_ENABLED:'true'}, {SINGULAR_API_KEY:'synthetic'}, {MEASUREMENT_CREDENTIAL_KEY: btoa('c'.repeat(32))}]) {
    const env={...candidate(),...measurement(),...linkedInTest(),...override};
    for (const [key,value] of Object.entries(override)) if (value === undefined) delete env[key];
    assert.throws(() => containerEnvironment(env), error => !error.message.includes('do_not_echo'), JSON.stringify(override));
  }
  // Without the test rule nothing changed: the switches and the token are refused as before.
  for (const override of [{FEATURE_LINKEDIN_CONVERSIONS_ENABLED:'true',FEATURE_CROSS_COMPANY_ADS_ENABLED:'true'},
    {LINKEDIN_CONVERSIONS_ACCESS_TOKEN:linkedInTest().LINKEDIN_CONVERSIONS_ACCESS_TOKEN}]) {
    assert.throws(() => containerEnvironment({...candidate(),...measurement(),...override}));
  }
  // The recovery image and a disabled platform never accept it.
  assert.throws(() => containerEnvironment({...sample(),...linkedInTest()}));
  assert.throws(() => containerEnvironment({...sample(),...platform(),...linkedInTest()}));
});
