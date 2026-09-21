import test from 'node:test';
import assert from 'node:assert/strict';
import {containerEnvironment} from '../src/config.mjs';

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
