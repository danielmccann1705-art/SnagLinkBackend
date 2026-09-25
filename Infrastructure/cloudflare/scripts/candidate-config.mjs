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
// **What "on" still costs.** The container's log is the whole Vapor log, not only
// B2.1's lines, so every line in it is published the moment this switch is on. Three
// lines used to carry a value that should not be published, and all three were
// redacted in the change that made the store readable — each keeps its level, its
// metadata shape and the operational fact it carried, and drops only the address:
//
//   * `WebReportController.swift` — the ZIP warning printed an object key under the
//     *public* upload bucket. That bucket serves without a signature, so the address
//     is the whole of the access. It now says a report photo was missing and skipped.
//   * `UploadController.swift` — printed the stored filename, which is the same
//     public key less its fixed prefix, on the success path of every completion photo
//     upload rather than on an error branch. It now says a completion photo was
//     stored, and whether the thumbnail was generated or fell back.
//   * `MagicLinkController.swift` — two photo/drawing sync lines printed the first
//     eight characters of the link token. Eight characters open nothing, but a
//     fragment of a capability in a seven-day store is only ever defended as
//     harmless. They now name the synced record's own id and nothing about the link.
//
// What remains is bounded and deliberate. `PrivateRequestLoggingMiddleware` logs the
// registered route pattern — parameter names, never their values — with a method and
// a status. B2.1's `kind:` words and the boot refusals are closed vocabularies that
// name a variable and never its contents. `APNsService` still logs an eight-character
// device-token prefix in four places; staging cannot reach it, because this adapter
// refuses `APNS_PRIVATE_KEY` outright, but production would, and it is the same class
// of partial credential as the two magic-link lines above. Twelve sites interpolate a
// caught `\(error)` — email, APNs, JSON decoding, thumbnailing and boot — which is not
// a known leak but is an unbounded surface, since a library's error description is
// not ours to predict. Neither is a reason to leave this switch on longer than the
// gate needs: set it back to off — by removing the variable — once that gate has run.
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

// Which stream the container writes its log on, and the marker that switches the
// one-run log-stream diagnostic on. Both live here for the same reason the logging
// switch does: they are deployment decisions, and `wrangler deploy` replaces the
// Worker's whole variable map, so a name this generator does not produce is a name
// the next deploy removes.
//
// **Why the stream is a variable at all.** The container emits nothing into the log
// store. The Worker's observability is on, the container's `logs.enabled` is on and
// in its current top-level placement, and over six hours the account's `containers`
// dataset held a thousand events of which not one was ours. Every line that does
// arrive, from the one other container on the account, looks like standard error.
// This process logs on standard output. That is a correlation and not a finding, so
// `LOG_STREAM_PROBE` tests it and `LOG_STREAM` makes the answer deployable: if the
// store turns out to keep standard error, the fix is this variable and a redeploy,
// not another thirty-two minute image build.
//
// **What the stream does not change.** Nothing about any line's text, level or
// metadata. The image keeps ConsoleKit's `ConsoleLogger` and its default renderer
// and only swaps the destination the handler holds. B2.1's `kind:` words are fixed
// strings from closed enums and cannot be reached from here.
export const logStreamVariable = 'SNAGLIST_CANDIDATE_LOG_STREAM';
export const logProbeVariable = 'SNAGLIST_CANDIDATE_LOG_PROBE';

// `stdout` unless the variable says otherwise, because `stdout` is where this image
// has always logged. Anything that is neither word is refused rather than quietly
// read as the default, for the reason the logging switch is: a variable set in order
// to move the log must not be able to leave it where it was and say nothing.
export function candidateLogStream(environment = process.env) {
  const setting = environment[logStreamVariable];
  if (setting === undefined || setting === '') return 'stdout';
  if (setting !== 'stdout' && setting !== 'stderr') {
    throw new Error(`${logStreamVariable} accepts only 'stdout' or 'stderr'; it is stdout when unset`);
  }
  return setting;
}

// Absent unless a run asks for one, and a run asks for one by naming a marker. The
// alphabet is uppercase letters, digits and the hyphen: narrow enough that no base64
// key, bearer, cookie or Contractor link token can be routed through it, which matters
// because the marker is written into a log line verbatim. A marker is meant to be
// unique to its run, so nothing already in the store can collide with it.
export function candidateLogProbe(environment = process.env) {
  const setting = environment[logProbeVariable];
  if (setting === undefined || setting === '') return undefined;
  if (!/^[A-Z0-9][A-Z0-9-]{6,46}[A-Z0-9]$/.test(setting)) {
    throw new Error(`${logProbeVariable} is 8 to 48 characters of A-Z, 0-9 and the hyphen; it is unset by default`);
  }
  return setting;
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
  const logStream = candidateLogStream(environment);
  const logProbe = candidateLogProbe(environment);
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
        // Sign in with Apple on the web: the staging Services ID for the manager
        // origin, beside the staging bundle the Worker's encrypted Apple bindings
        // name and never instead of it. Public identifiers, like the Google clients
        // above. src/config.mjs refuses the identity without its switch, the switch
        // without the exact identity, and either without the Apple token exchange
        // the web flow signs its client secret with; the container additionally
        // reports the web flow disabled unless all three agree with PORTAL_ORIGIN.
        // The Services ID is a registration in Apple Developer that the deployer
        // reads back before a deploy carrying this; an unregistered ID fails
        // visibly at Apple's authorize page and never at the callback.
        APPLE_WEB_ENABLED:'true',APPLE_WEB_AUTH_ENVIRONMENT:'staging',
        APPLE_WEB_CLIENT_ID:'com.snaglist.app.staging.web',
        R2_ACCOUNT_ID:'387d49014cd0d45f9e6434196ab513c0',R2_BUCKET_NAME:'snaglist-unified-staging-uploads',
        R2_PUBLIC_URL:'https://pub-d7c456d4b396462fb5ee8ef008dcf93b.r2.dev',
        R2_PRIVATE_BUCKET_NAME:'snaglist-staging-private',R2_PRIVATE_NAMESPACE:'private-v1/',
        // Live on the candidate Worker since 17 September. The generator not knowing
        // them is what would have made a regenerated deploy drop them.
        STAGED_LEGACY_IMPORT_ENABLED:'true',IMPORT_PREVIEW_API_ORIGIN:candidateOrigin,
        // Written down explicitly off. Turning account deletion on stays a separate
        // reviewed act; naming it here only stops a deploy deciding it by omission.
        ACCOUNT_DELETION_ENABLED:'false',
        // Which stream the container's log leaves on. Written down in both states
        // rather than left unset, so the generated file says where the log goes
        // instead of leaving that to a default a reader has to know. The reason the
        // variable exists at all is recorded on `logStreamVariable` above.
        LOG_STREAM:logStream,
        // Present only for a deliberate one-run diagnostic. Absent is the normal
        // state, and a configuration generated without it is one with the probe off.
        ...(logProbe ? {LOG_STREAM_PROBE:logProbe} : {})},
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
  const logStream = candidateLogStream();
  const logProbe = candidateLogProbe();
  console.log('Prepared disabled candidate configurations. No deployment or resource change performed.');
  console.log(`Container log stream: ${logStream} (${logStreamVariable}${logStream === 'stdout' ? ' unset' : '=' + logStream}).`);
  console.log(logProbe
    ? `Log-stream probe: ON, marker ${logProbe}. Boot and every /health request emit one line per stream. Regenerate with ${logProbeVariable} unset once the run has been read.`
    : `Log-stream probe: off (default). Set ${logProbeVariable} to a marker to emit one line per stream at boot and on every /health request.`);
  console.log(logging
    ? `Logging: ON (${loggingVariable}=on), narrowed. The Worker's observability and the container's logs are on so B2.1's per-write kind: lines reach the store; invocation_logs is off, so request URLs — which on this product carry capability tokens — are not recorded. Read the lines in the dashboard rather than exporting the store, and regenerate with the variable unset once the gate that needed it has run.`
    : `Logging: off (default). Set ${loggingVariable}=on to generate with the Worker's observability and the container's logs enabled for the B5 gate.`);
}
