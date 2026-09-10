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
