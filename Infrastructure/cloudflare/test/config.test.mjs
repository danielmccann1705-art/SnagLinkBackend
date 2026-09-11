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
