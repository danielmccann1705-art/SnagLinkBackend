import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {candidateConfigs,candidateLogging,candidateLogProbe,candidateLogStream,candidateOrigin,
  logProbeVariable,loggingVariable,logStreamVariable,managerOrigin} from '../scripts/candidate-config.mjs';
import {containerEnvironment} from '../src/config.mjs';

// `environment` is supplied everywhere here so an ambient logging variable cannot
// decide what the rest of this file sees; the switch has its own tests below.
const configs=(environment={})=>candidateConfigs({imageDigest:'sha256:'+'a'.repeat(64),
  assetsDirectory:'/synthetic/immutable/dist',environment});
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
// D4 writes the deletion switch down as an explicit 'false' instead of leaving a
// deploy to decide it by omission. Written down off is still off.
test('the candidate carries the pinned private namespace with account deletion still off',()=>{
  const {backend}=configs();
  assert.equal(backend.vars.R2_PRIVATE_NAMESPACE,'private-v1/');
  assert.equal(backend.vars.ACCOUNT_DELETION_ENABLED,'false');
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

// A deploy replaces the Worker's whole variable map, so every non-secret variable
// the adapter reads has to be produced here or the next deploy removes it from the
// live Worker. Restating today's list would only repeat the generator, so the list
// is read out of the adapter instead: add `env.NEW_FLAG` to src/config.mjs and set
// it by hand on the Worker, and this fails until the generator produces it too.
// Every name src/config.mjs mentions must land in exactly one of the four buckets
// below, so a new one cannot pass unnoticed as "something else".
const adapterSource=readFileSync(new URL('../src/config.mjs',import.meta.url),'utf8');
const adapterReads=new Set([
  ...adapterSource.matchAll(/\benv\.([A-Z][A-Z0-9_]*)/g),
  // Names reached through env[key] appear only as string literals in the arrays the
  // adapter loops over. Requiring an underscore keeps ordinary constants out.
  ...adapterSource.matchAll(/'([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)'/g)
].map(match=>match[1]));

// Separate encrypted bindings. A deploy does not replace them and the generated
// configuration must never carry them, which is what puts them in the image.
const secretBindings=['DATABASE_URL','JWT_SECRET','LINK_GRANT_TOKEN_KEY','LINK_GRANT_TOKEN_PREVIOUS_KEY',
  'R2_ACCESS_KEY_ID','R2_SECRET_ACCESS_KEY','RESEND_API_KEY','MAINTENANCE_SECRET',
  'APPLE_PRIVATE_KEY','APPLE_CREDENTIAL_KEY','APPLE_CREDENTIAL_PREVIOUS_KEY'];
// Named in the adapter only so it can refuse them: staging has no purchase or push provider.
const refusedInStaging=['REVENUECAT_SECRET_API_KEY','APNS_PRIVATE_KEY'];
// Understood by the adapter and deliberately not configured on this candidate.
const notCarried=new Map([
  ['EMAIL_FROM','candidate email is disabled; STAGING_EMAIL_ENABLED is false'],
  ['EMAIL_ALLOWED_RECIPIENTS','candidate email is disabled'],
  ['APPLE_BUNDLE_ID','Apple sign-in is not configured on the candidate'],
  ['APPLE_CLIENT_ID','Apple sign-in is not configured on the candidate'],
  ['APPLE_TEAM_ID','the Apple token exchange is not configured on the candidate'],
  ['APPLE_KEY_ID','the Apple token exchange is not configured on the candidate'],
  // A one-run diagnostic marker, not a setting. The generator produces it only when
  // SNAGLIST_CANDIDATE_LOG_PROBE names one for that generation, so a configuration
  // generated without it is one with the probe off - which is the normal state and
  // the state a deploy should return the Worker to once a run has been read.
  ['LOG_STREAM_PROBE','the log-stream probe is per-run; the generator carries it only when asked']
]);

test('the generated variable map is exactly the non-secret configuration the adapter reads',()=>{
  const carried=new Set(Object.keys(configs().backend.vars));
  const excluded=new Set([...secretBindings,...refusedInStaging,...notCarried.keys()]);
  const shouldCarry=[...adapterReads].filter(name=>!excluded.has(name)).sort();
  assert.deepEqual([...carried].sort(),shouldCarry,
    'A deploy replaces the whole variable map, so every non-secret variable src/config.mjs reads must be '+
    'produced by scripts/candidate-config.mjs. Add the new variable there, or classify it in this file as '+
    'an encrypted secret, a refusal, or deliberately not carried by the candidate.');
  for (const name of excluded) {
    assert.equal(carried.has(name),false,`${name} must not be deployed as a plain Worker variable`);
    assert.equal(adapterReads.has(name),true,`${name} is no longer read by the adapter; drop the stale exclusion`);
  }
});

// Read back from the 18 September deploy of snaglist-api-unified-staging. A record
// of what is live, not a second source of truth: it catches a name being dropped
// from the generator, and it cannot see one set by hand on the dashboard that the
// adapter never reads.
const liveWorkerVariables=['BASE_URL','GOOGLE_AUTH_ENVIRONMENT','GOOGLE_IOS_CLIENT_ID','GOOGLE_WEB_CLIENT_ID',
  'IMPORT_PREVIEW_API_ORIGIN','MAGIC_LINK_BASE_URL','PLATFORM_ENVIRONMENT','PORTAL_ORIGIN','R2_ACCOUNT_ID',
  'R2_BUCKET_NAME','R2_PRIVATE_BUCKET_NAME','R2_PUBLIC_URL','STAGED_LEGACY_IMPORT_ENABLED','STAGING_DATABASE_HOST',
  'STAGING_DEPLOYMENT','STAGING_EMAIL_ENABLED','STAGING_ENABLED','STAGING_PLATFORM_ENABLED'];

test('a regenerated deploy replaces every variable the live candidate Worker already carries',()=>{
  const {backend}=configs();
  for (const name of liveWorkerVariables) {
    assert.notEqual(backend.vars[name],undefined,
      `${name} is live on the candidate Worker; a deploy generated without it drops it`);
  }
  assert.equal(backend.vars.STAGED_LEGACY_IMPORT_ENABLED,'true');
  assert.equal(backend.vars.IMPORT_PREVIEW_API_ORIGIN,candidateOrigin);
  // The container sleeps after ten minutes and the cron is what wakes it; the same
  // deploy replaces this too.
  assert.deepEqual(backend.triggers.crons,['0 * * * *']);
});

// Logging is a switch and its safe state is the default one. Cloudflare's invocation
// logs, whose message for a fetch is the request method and the request URL, are what
// makes Worker logging dangerous here — Snaglist's capability tokens live in URL
// paths. So the generator produces logging off unless `SNAGLIST_CANDIDATE_LOGGING=on`
// was set for that generation, and writes both states down in full rather than
// leaving a reader to know a platform default. `on` is narrowed to what the B5 gate
// actually reads: the Worker's observability and the container's logs on, so B2.1's
// per-write `kind:` lines reach the store, and `invocation_logs` off, so request URLs
// are never recorded. The reason is recorded once on `loggingVariable`.
test('the staging candidate generates with logging off unless the switch is turned on',()=>{
  const {backend,portal}=configs();
  assert.equal(backend.observability.enabled,false,'logging is off unless deliberately turned on');
  assert.equal(backend.observability.logs.enabled,false);
  assert.equal(backend.observability.logs.invocation_logs,false,
    'invocation logs carry the request URL, and Snaglist URL paths carry capability tokens');
  assert.equal(backend.containers[0].observability.logs.enabled,false);
  assert.equal(portal.observability.enabled,false,'the portal carries browser URLs; it stays quiet');
  assert.equal(backend.name,'snaglist-api-unified-staging');
  assert.equal(backend.vars.PLATFORM_ENVIRONMENT,'staging');
});

test('the switch turns the Worker and the container on together, and nothing else',()=>{
  const off=configs().backend;
  const {backend,portal}=configs({[loggingVariable]:'on'});
  assert.equal(backend.observability.enabled,true);
  assert.equal(backend.observability.logs.enabled,true);
  assert.equal(backend.observability.logs.invocation_logs,false,
    'on is narrowed: the invocation log records the request method and URL, and the B5 gate drives '+
    'the Contractor link path, so on must never turn that line on');
  // Written down in full, and exactly these three keys: an added key would be a
  // platform default nobody chose.
  assert.deepEqual(backend.observability,{enabled:true,logs:{enabled:true,invocation_logs:false}});
  // The container's stdout is where B2.1's `kind:` lines are, and it reaches the
  // dashboard only when the Worker's observability is on too.
  assert.equal(backend.containers[0].observability.logs.enabled,true);
  assert.equal(portal.observability.enabled,false,'the switch never speaks for the portal');
  // Nothing but the observability settings moves. A logging decision is not a
  // licence to change a variable, an origin, a bucket or the pinned image.
  assert.deepEqual({...backend,observability:null,containers:null},
                   {...off,observability:null,containers:null});
  assert.deepEqual(backend.vars,off.vars);
  assert.deepEqual({...backend.containers[0],observability:null},
                   {...off.containers[0],observability:null});
});

test('the logging switch reads one variable, defaults off, and refuses anything else',()=>{
  assert.equal(candidateLogging({}),false);
  assert.equal(candidateLogging({[loggingVariable]:''}),false);
  assert.equal(candidateLogging({[loggingVariable]:'off'}),false);
  assert.equal(candidateLogging({[loggingVariable]:'on'}),true);
  // A typo must not be read as the safe state either: a switch that exists to make a
  // state deliberate may not let a misspelling choose one for it.
  for (const value of ['true','1','yes','ON','On','enabled','false']) {
    assert.throws(()=>candidateLogging({[loggingVariable]:value}),
      new RegExp(`${loggingVariable}`),`${loggingVariable}=${value} must be refused, not read as off`);
  }
  assert.throws(()=>candidateConfigs({imageDigest:'sha256:'+'a'.repeat(64),
    assetsDirectory:'/synthetic/immutable/dist',environment:{[loggingVariable]:'yes'}}));
});

// The generator reads the switch off the real process environment when it is not
// given one, which is how the command-line path in this file gets it.
test('an unset variable in the real process environment generates logging off',()=>{
  const previous=process.env[loggingVariable];
  try {
    delete process.env[loggingVariable];
    assert.equal(candidateLogging(),false);
    const {backend}=candidateConfigs({imageDigest:'sha256:'+'a'.repeat(64),
      assetsDirectory:'/synthetic/immutable/dist'});
    assert.equal(backend.observability.enabled,false);
    assert.equal(backend.containers[0].observability.logs.enabled,false);
    process.env[loggingVariable]='on';
    assert.equal(candidateLogging(),true);
    assert.equal(candidateConfigs({imageDigest:'sha256:'+'a'.repeat(64),
      assetsDirectory:'/synthetic/immutable/dist'}).backend.observability.enabled,true);
  } finally {
    if (previous===undefined) delete process.env[loggingVariable]; else process.env[loggingVariable]=previous;
  }
});

// The stream the container logs on is a deployment decision and therefore lives in
// the generated variable map: `wrangler deploy` replaces that map wholesale, so a
// stream the generator does not produce is a stream the next deploy unsets. It is
// written down in both states for the same reason the observability block is - so
// the generated file says where the log goes rather than leaving it to a default.
test('the container log stream is generated in both states and defaults to stdout',()=>{
  assert.equal(configs().backend.vars.LOG_STREAM,'stdout','unset is today\'s behaviour, written down');
  assert.equal(configs({[logStreamVariable]:'stdout'}).backend.vars.LOG_STREAM,'stdout');
  assert.equal(configs({[logStreamVariable]:'stderr'}).backend.vars.LOG_STREAM,'stderr');
  // Moving the log is not a licence to move anything else.
  const out=configs({[logStreamVariable]:'stdout'}).backend;
  const err=configs({[logStreamVariable]:'stderr'}).backend;
  assert.deepEqual({...err,vars:null},{...out,vars:null});
  assert.deepEqual({...err.vars,LOG_STREAM:null},{...out.vars,LOG_STREAM:null});
});

test('the log stream switch reads one variable, defaults to stdout, and refuses anything else',()=>{
  assert.equal(candidateLogStream({}),'stdout');
  assert.equal(candidateLogStream({[logStreamVariable]:''}),'stdout');
  assert.equal(candidateLogStream({[logStreamVariable]:'stdout'}),'stdout');
  assert.equal(candidateLogStream({[logStreamVariable]:'stderr'}),'stderr');
  for(const value of ['STDERR','stderr ','2','both','/dev/stderr','on']) {
    assert.throws(()=>candidateLogStream({[logStreamVariable]:value}));
  }
});

// The probe is a diagnostic, not a setting: it exists to decide which stream the
// store keeps, in one image build, and then to be turned back off. Off is therefore
// absence - no variable, no marker, no probe line - and not a written-down `false`.
test('the log-stream probe is absent unless a run names a marker',()=>{
  assert.equal(configs().backend.vars.LOG_STREAM_PROBE,undefined);
  assert.equal(configs({[logProbeVariable]:'STREAM-0921-A'}).backend.vars.LOG_STREAM_PROBE,'STREAM-0921-A');
  // Naming a marker moves nothing else at all.
  const off=configs().backend;
  const on=configs({[logProbeVariable]:'STREAM-0921-A'}).backend;
  assert.deepEqual({...on,vars:null},{...off,vars:null});
  assert.deepEqual({...on.vars,LOG_STREAM_PROBE:null},{...off.vars,LOG_STREAM_PROBE:null});
});

test('a probe marker cannot carry a secret into a log line',()=>{
  assert.equal(candidateLogProbe({}),undefined);
  assert.equal(candidateLogProbe({[logProbeVariable]:''}),undefined);
  for(const marker of ['SNAG0921A','A1B2C3D4','STREAM-0921-A','X'.repeat(48)]) {
    assert.equal(candidateLogProbe({[logProbeVariable]:marker}),marker);
  }
  // Too short, too long, hyphen-edged, or outside the alphabet. The last four are the
  // point of the alphabet: a base64 key, a bearer, a cookie value and a padded 32-byte
  // key all carry lowercase or one of + / = and so none of them can pass through here.
  for(const marker of ['SHORT7','Y'.repeat(49),'-SNAG0921','SNAG0921-','SNAG 0921',
    'c25hZ2xpc3Qtc3ludGhldGlj','Bearer-abc123','sid=0123456789abcdef','A'.repeat(42)+'=']) {
    assert.throws(()=>candidateLogProbe({[logProbeVariable]:marker}));
  }
});
