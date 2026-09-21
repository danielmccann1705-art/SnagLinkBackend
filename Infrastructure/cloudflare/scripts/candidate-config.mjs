import {fileURLToPath} from 'node:url';
import {dirname, isAbsolute, join, resolve} from 'node:path';
import {mkdirSync, writeFileSync} from 'node:fs';

const infrastructure = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const candidateOrigin = 'https://snaglist-api-unified-staging.danielmccann1705.workers.dev';
export const managerOrigin = 'https://staging-app.usesnaglist.com';
export const candidateDatabase = 'snaglist_platform_test_0910222943_fc44';

// Logging on the staging candidate is a switch, and the switch is off unless it is
// deliberately turned on at generation time. This is the one place the decision and
// its reason are written down.
//
// **Why it is off by default.** Turning `observability` on for the backend Worker
// also turns on Cloudflare's *invocation logs*, whose message for a fetch event is
// the request method and the request URL. Snaglist's capability tokens live in URL
// paths —
// `/m/:slug`, `/link/:token`, `/preview/:token`, `/auth/:token`,
// `/api/v1/magic-links/:token/...` and the `/api/v2/contractor/:token/...` Contractor
// link path the B5 gate itself drives — so a Worker left to log everything records
// a bearer URL in a store that is read by more people, and kept in more places, than
// the service it describes. The application's own request logging never writes a URL
// (`PrivateRequestLoggingMiddleware` logs the registered route pattern and a status
// code and nothing else), but an invocation log is the platform's line, not the
// application's, and no application change can suppress it.
//
// **Why it exists at all.** The B5 gate reads the per-write `kind:` lines that B2.1
// added — one fixed word per private-media write, chosen at the call site from a
// closed enum. Those lines leave the Vapor process on stdout, and container stdout
// reaches the dashboard only when the *Worker's* `observability` is on as well
// (https://developers.cloudflare.com/containers/faq/). The Worker's
// `observability.enabled` is therefore what carries the container's lines: B5 cannot
// read a `kind:` line without it, and it is what brings the invocation log with it
// unless that line is named off — which is what `on` now does.
//
// **What "on" means.** On is narrowed to exactly what the B5 gate reads. The
// Worker's `observability.enabled` and the container's `logs.enabled` are true, so
// B2.1's per-write `kind:` lines leave the container and reach the store; the
// Worker's `logs.invocation_logs` is **false**, so the line that would record the
// request method and URL is not written at all. That is Dan's decision of
// 21 September on the log-exposure audit of the same date: the `kind:` lines are a
// closed vocabulary carrying no value, the invocation log is the one line that would
// carry a Contractor link token, and the gate needs the first without the second.
// The backend Worker's own code logs nothing — no `console.*` anywhere in `src/` —
// so with invocation logs off the Worker adds no line of its own and the container's
// stdout is all that flows.
//
// **What "on" still costs.** The container's stdout is the whole Vapor log, not only
// B2.1's lines, and one live line still interpolates a value: the ZIP warning in
// `WebReportController.swift` prints an object key under the *public* upload bucket.
// That is an address rather than a credential, but it is a capability by knowledge,
// so a wholesale export or screenshot of the log store is still not an evidence-grade
// artefact — B2.1's `kind:` lines themselves are safe to quote. Set the switch back
// to off — by removing the variable — as soon as the gate that needed it has run.
//
// Production and the recovery Worker are not this switch's business. They keep
// logging off unconditionally in their own configurations, which this file does not
// generate and must not be made to.
export const loggingVariable = 'SNAGLIST_CANDIDATE_LOGGING';

// Off unless the variable is exactly 'on'. A value that is neither 'on' nor 'off' is
// refused rather than quietly read as off: a switch whose whole purpose is to make a
// state deliberate must not let a typo choose either state for it.
export function candidateLogging(environment = process.env) {
  const setting = environment[loggingVariable];
  if (setting === undefined || setting === '') return false;
  if (setting !== 'on' && setting !== 'off') {
    throw new Error(`${loggingVariable} accepts only 'on' or 'off'; it is off when unset`);
  }
  return setting === 'on';
}

// Produces disabled configurations only. No secrets, live Worker mutation,
// registry push, database creation or resource inference happens here.
//
// `wrangler deploy` replaces a Worker's whole variable map, so a name missing from
// the map below is a name the next deploy silently removes from the live Worker.
// The backend map is therefore the complete set of non-secret variables the adapter
// reads, including the switches that are deliberately off; it is not a minimum.
// `test/candidate.test.mjs` holds it to exactly that set. Secrets stay out: they are
// separate encrypted bindings that a deploy does not touch.
export function candidateConfigs({imageDigest, assetsDirectory, environment = process.env}) {
  if (!/^sha256:[a-f0-9]{64}$/.test(imageDigest) || /^sha256:0+$/.test(imageDigest)) {
    throw new Error('Supply the verified immutable candidate registry image digest');
  }
  if (!isAbsolute(assetsDirectory)) throw new Error('Use the absolute immutable portal dist directory');
  const logging = candidateLogging(environment);
  return {
    backend: {
      $schema:join(infrastructure,'node_modules/wrangler/config-schema.json'),
      name:'snaglist-api-unified-staging', main:join(infrastructure,'src/index.ts'),
      compatibility_date:'2026-09-09', workers_dev:true, preview_urls:false,
      // Off unless `SNAGLIST_CANDIDATE_LOGGING=on` was set for this generation; the
      // decision and its reason are recorded on `loggingVariable` above. Both states
      // are written down in full, `invocation_logs` included, so the generated file
      // says plainly whether request URLs will be recorded instead of leaving it to
      // a platform default that a reader has to know. `invocation_logs` is false in
      // both states, and that is the whole of the difference between `on` and what
      // `on` used to mean: turning the switch on lets the container's `kind:` lines
      // through and never turns on the platform line that records the request method
      // and URL.
      observability: logging
        ? {enabled:true,logs:{enabled:true,invocation_logs:false}}
        : {enabled:false,logs:{enabled:false,invocation_logs:false}},
      vars:{STAGING_ENABLED:'false',STAGING_DEPLOYMENT:'unified-candidate',STAGING_PLATFORM_ENABLED:'true',
        STAGING_DATABASE_HOST:'ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech',
        STAGING_EMAIL_ENABLED:'false',BASE_URL:candidateOrigin,MAGIC_LINK_BASE_URL:candidateOrigin,
        PLATFORM_ENVIRONMENT:'staging',PORTAL_ORIGIN:managerOrigin,
        GOOGLE_AUTH_ENVIRONMENT:'staging',
        GOOGLE_WEB_CLIENT_ID:'853801285577-3dmk0mtkjf9gcummuq374urgim0ohgp9.apps.googleusercontent.com',
        GOOGLE_IOS_CLIENT_ID:'853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0.apps.googleusercontent.com',
        R2_ACCOUNT_ID:'387d49014cd0d45f9e6434196ab513c0',R2_BUCKET_NAME:'snaglist-unified-staging-uploads',
        R2_PUBLIC_URL:'https://pub-d7c456d4b396462fb5ee8ef008dcf93b.r2.dev',
        R2_PRIVATE_BUCKET_NAME:'snaglist-staging-private',R2_PRIVATE_NAMESPACE:'private-v1/',
        // Live on the candidate Worker since 17 September. The generator not knowing
        // them is what would have made a regenerated deploy drop them.
        STAGED_LEGACY_IMPORT_ENABLED:'true',IMPORT_PREVIEW_API_ORIGIN:candidateOrigin,
        // Written down explicitly off. Turning account deletion on stays a separate
        // reviewed act; naming it here only stops a deploy deciding it by omission.
        ACCOUNT_DELETION_ENABLED:'false'},
      containers:[{class_name:'SnaglistBackend',
        image:`registry.cloudflare.com/387d49014cd0d45f9e6434196ab513c0/snaglist-unified-staging@${imageDigest}`,
        instance_type:'basic',max_instances:1,constraints:{regions:['WEUR']},observability:{logs:{enabled:logging}}}],
      durable_objects:{bindings:[{name:'BACKEND',class_name:'SnaglistBackend'}]},
      migrations:[{tag:'v1',new_sqlite_classes:['SnaglistBackend']}],
      // The container sleeps after ten minutes and the cron is what wakes it. The
      // live Worker carries this schedule and the generator did not — the same
      // omission as the variables above, in the same replaced configuration.
      triggers:{crons:['0 * * * *']}
    },
    portal: {
      $schema:join(infrastructure,'node_modules/wrangler/config-schema.json'),
      name:'snaglist-portal-unified-staging', main:join(infrastructure,'src/portal.ts'),
      compatibility_date:'2026-09-09',workers_dev:false,preview_urls:false,observability:{enabled:false},
      routes:[{pattern:'staging-app.usesnaglist.com',custom_domain:true}],
      vars:{STAGING_PORTAL_ENABLED:'false',PORTAL_ORIGIN:managerOrigin},
      services:[{binding:'BACKEND',service:'snaglist-api-unified-staging'}],
      assets:{directory:assetsDirectory,binding:'ASSETS',not_found_handling:'single-page-application',run_worker_first:true}
    }
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [imageDigest,assetsDirectory,outputDirectory] = process.argv.slice(2);
  if (!outputDirectory || !isAbsolute(outputDirectory)) throw new Error('Usage: node candidate-config.mjs IMAGE_DIGEST /absolute/dist /absolute/output');
  const configs=candidateConfigs({imageDigest,assetsDirectory});
  mkdirSync(outputDirectory,{recursive:true});
  for(const [name,config] of Object.entries(configs)) {
    writeFileSync(join(outputDirectory,`${name}.json`),JSON.stringify(config,null,2)+'\n',{flag:'wx'});
  }
  const logging = candidateLogging();
  console.log('Prepared disabled candidate configurations. No deployment or resource change performed.');
  console.log(logging
    ? `Logging: ON (${loggingVariable}=on), narrowed. The Worker's observability and the container's logs are on so B2.1's per-write kind: lines reach the store; invocation_logs is off, so request URLs — which on this product carry capability tokens — are not recorded. Read the lines in the dashboard rather than exporting the store, and regenerate with the variable unset once the gate that needed it has run.`
    : `Logging: off (default). Set ${loggingVariable}=on to generate with the Worker's observability and the container's logs enabled for the B5 gate.`);
}
