import test from 'node:test';
import assert from 'node:assert/strict';
import {candidateConfigs,candidateOrigin,managerOrigin} from '../scripts/candidate-config.mjs';
import {containerEnvironment} from '../src/config.mjs';

const configs=()=>candidateConfigs({imageDigest:'sha256:'+'a'.repeat(64),assetsDirectory:'/synthetic/immutable/dist'});
const enabled=()=>({...configs().backend.vars,STAGING_ENABLED:'true',
  DATABASE_URL:'postgresql://synthetic:synthetic@ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech/snaglist_platform_test_0910222943_fc44?sslmode=require',
  JWT_SECRET:'synthetic-only-jwt-at-least-32-characters',LINK_GRANT_TOKEN_KEY:btoa('z'.repeat(32)),
  R2_ACCESS_KEY_ID:'synthetic',R2_SECRET_ACCESS_KEY:'synthetic'});

test('candidate and portal configurations are disabled, digest-pinned and isolated from recovery',()=>{
  const {backend,portal}=configs();
  assert.equal(backend.name,'snaglist-api-unified-staging');
  assert.equal(backend.routes,undefined);
  assert.equal(backend.vars.STAGING_ENABLED,'false');
  assert.equal(portal.vars.STAGING_PORTAL_ENABLED,'false');
  assert.equal(backend.vars.BASE_URL,candidateOrigin);
  assert.equal(backend.vars.MAGIC_LINK_BASE_URL,candidateOrigin);
  assert.equal(backend.vars.PORTAL_ORIGIN,managerOrigin);
  assert.match(backend.containers[0].image,/\/snaglist-unified-staging@sha256:[a-f0-9]{64}$/);
  assert.equal(portal.services[0].service,backend.name);
  assert.equal(portal.routes[0].pattern,'staging-app.usesnaglist.com');
  assert.equal(portal.workers_dev,false);
  assert.equal(portal.assets.run_worker_first,true,'Disabled portal/API guard must run before SPA fallback');
  for(const key of ['DATABASE_URL','JWT_SECRET','LINK_GRANT_TOKEN_KEY','R2_ACCESS_KEY_ID','R2_SECRET_ACCESS_KEY','RESEND_API_KEY']) {
    assert.equal(backend.vars[key],undefined);
  }
});

// D1 carries the namespace into the candidate; it does not turn deletion on.
// The two switches are separate acts, and only the first one is code's to make.
test('the candidate carries the pinned private namespace with account deletion still off',()=>{
  const {backend}=configs();
  assert.equal(backend.vars.R2_PRIVATE_NAMESPACE,'private-v1/');
  assert.equal(backend.vars.ACCOUNT_DELETION_ENABLED,undefined);
  const output=containerEnvironment(enabled());
  assert.equal(output.R2_PRIVATE_NAMESPACE,'private-v1/');
  assert.equal(output.ACCOUNT_DELETION_ENABLED,'false');
});

test('mutable image tags and incomplete/relative asset inputs cannot produce deployment config',()=>{
  for(const imageDigest of ['latest','sha256:'+'0'.repeat(64),'sha256:abcd','sha256:'+'G'.repeat(64)]) {
    assert.throws(()=>candidateConfigs({imageDigest,assetsDirectory:'/synthetic/dist'}));
  }
  assert.throws(()=>candidateConfigs({imageDigest:'sha256:'+'a'.repeat(64),assetsDirectory:'../dist'}));
});

test('candidate accepts only its pinned synthetic DB, origins and independent buckets',()=>{
  const output=containerEnvironment(enabled());
  assert.equal(output.BASE_URL,candidateOrigin);
  assert.equal(output.R2_PRIVATE_BUCKET_NAME,'snaglist-staging-private');
  assert.equal(output.R2_BUCKET_NAME,'snaglist-unified-staging-uploads');
  assert.equal(output.STAGING_DEPLOYMENT,undefined);
  for(const override of [
    {STAGING_DEPLOYMENT:'production'}, {STAGING_DEPLOYMENT:undefined},
    {STAGING_PLATFORM_ENABLED:'false'},
    {DATABASE_URL:enabled().DATABASE_URL.replace('0910222943_fc44','0911074529_fa3f')},
    {STAGING_DATABASE_HOST:'ep-bitter-wave-zacpbrh7.c-2.eu-west-2.aws.neon.tech'},
    {R2_BUCKET_NAME:'snaglist-staging-uploads'}, {R2_BUCKET_NAME:'snaglist-uploads'},
    {R2_ACCOUNT_ID:'another-account'}, {R2_PUBLIC_URL:'https://cdn.snaglist.dev'},
    {BASE_URL:'https://snaglist-api-staging.danielmccann1705.workers.dev'},
    {MAGIC_LINK_BASE_URL:'https://snaglist-api-staging.danielmccann1705.workers.dev'}
  ]) assert.throws(()=>containerEnvironment({...enabled(),...override}));
});
