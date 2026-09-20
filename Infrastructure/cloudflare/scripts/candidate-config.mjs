import {fileURLToPath} from 'node:url';
import {dirname, isAbsolute, join, resolve} from 'node:path';
import {mkdirSync, writeFileSync} from 'node:fs';

const infrastructure = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const candidateOrigin = 'https://snaglist-api-unified-staging.danielmccann1705.workers.dev';
export const managerOrigin = 'https://staging-app.usesnaglist.com';
export const candidateDatabase = 'snaglist_platform_test_0910222943_fc44';

// Produces disabled configurations only. No secrets, live Worker mutation,
// registry push, database creation or resource inference happens here.
//
// `wrangler deploy` replaces a Worker's whole variable map, so a name missing from
// the map below is a name the next deploy silently removes from the live Worker.
// The backend map is therefore the complete set of non-secret variables the adapter
// reads, including the switches that are deliberately off; it is not a minimum.
// `test/candidate.test.mjs` holds it to exactly that set. Secrets stay out: they are
// separate encrypted bindings that a deploy does not touch.
export function candidateConfigs({imageDigest, assetsDirectory}) {
  if (!/^sha256:[a-f0-9]{64}$/.test(imageDigest) || /^sha256:0+$/.test(imageDigest)) {
    throw new Error('Supply the verified immutable candidate registry image digest');
  }
  if (!isAbsolute(assetsDirectory)) throw new Error('Use the absolute immutable portal dist directory');
  return {
    backend: {
      $schema:join(infrastructure,'node_modules/wrangler/config-schema.json'),
      name:'snaglist-api-unified-staging', main:join(infrastructure,'src/index.ts'),
      compatibility_date:'2026-09-09', workers_dev:true, preview_urls:false,
      // Staging candidate only. B5 and the journey run read per-write `kind:` lines
      // off this Worker, and there is nothing to read unless invocation logs exist.
      // Production and the recovery Worker keep logging off: auth and Contractor
      // tokens occur in their URL paths. This candidate carries synthetic data only.
      observability:{enabled:true},
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
        instance_type:'basic',max_instances:1,constraints:{regions:['WEUR']},observability:{logs:{enabled:true}}}],
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
  console.log('Prepared disabled candidate configurations. No deployment or resource change performed.');
}
