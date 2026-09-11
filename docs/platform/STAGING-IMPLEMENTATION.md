# Snaglist unified staging implementation

## Current checkpoint — 11 September, 19:28 UTC

**Both isolated staging Workers and the pinned container image are now deployed with application access disabled.** Read [STAGING-CANDIDATE-DEPLOYMENT.md](STAGING-CANDIDATE-DEPLOYMENT.md) for exact deployment IDs, registry digest, bindings and observed access limitations. This supersedes the historical preparation statements below that say no service/image was deployed.

Frozen backend `91a53d9` and portal `e250765` remain separate from newer tested working source. The backend has no encrypted secret bindings, portal enablement is false, and real database/media/provider/close-out acceptance has not run. The pending 30-day credential is limited to the two new candidate buckets. Current automated HTTP probes encounter Cloudflare1010; browser navigation is blocked by the client. R0 remains open. Recovery and production were not replaced.

## Earlier preparation and evidence

Updated 11 September 2026. This checkpoint covers isolated staging preparation only. **R0 is not closed:** the exact baseline Linux product builds, but the matching unified service/portal have not been deployed, new R2 objects have not been uploaded/read through the app, and real staging provider exchanges remain unverified. Production and the existing recovery service remain unchanged. The root-selected next backend checkpoint is `91a53d97e47346bfe4c96da2378e0aac12927046`; its matching image is being built separately by root. See [the concrete deployment sequence](STAGING-DEPLOYMENT-SEQUENCE.md) for current credential/API observations and ordered execution.

## Completed and observed

| Item | Exact result | Evidence / limitation |
| --- | --- | --- |
| Immutable backend source | Commit `a23fe3e4075902fec1d90055975c9f22d88dfada`, 217 committed build files; canonical context SHA-256 `200f0c0beac69d9dd37c7a4b5d7b4c9de28f558d1ae35cf7632b4e16e3ef2df5` | `STAGING-SOURCE-MANIFEST.json`; independent export matched the actual build directory. Concurrent backend graph changes are excluded. |
| Linux/amd64 product image | Docker build completed, exit 0. Local image `snaglist-unified-staging:a23fe3e`; image index digest `sha256:226f378128d0d7920e37dde467f291df4faa723b64c582d479c57066f10caef3`; platform manifest `sha256:8841c69f33a3b7be52fb68979361f0704f428cf39ec632436ef32ca181ac0536`; config digest `sha256:f19b0f8779ebaa279802925a36f506ba3244cc3ce2ade227ea3f09fa4e1194fe` | `staging-evidence/a23fe3e-linux-build.log` and `a23fe3e-image-id.txt`. Product build does not execute tests. Image has not been pushed to the registry or deployed. |
| Image runtime smoke | Passed: Linux/amd64, non-root UID 1000, all nine Contractor resources, exact bounded ImageMagick options on a synthetic 640×480 PNG, one-frame JPEG and metadata comment removed. | `staging-evidence/a23fe3e-runtime-smoke.log`; network disabled/read-only rootfs. This is not app API/R2/database acceptance. |
| Retained synthetic backup + restore | Passed: consistent remote read-only snapshot; private dump; all **53 tables** restored to an own disposable no-network local PostgreSQL16 container with identical row counts and SHA-256 fingerprints. Container cleaned up. | `STAGING-BACKUP-RESTORE.json`; no remote write/create/drop/migration. Private dump must not be uploaded to Drive. |
| Adapter/proxy/build-export/compatibility tests | **29 passed; zero failures or skips** after root applied the compatibility guard and public Google config. TypeScript check passed. | `staging-evidence/adapter-final-tests.log`, `adapter-final-typecheck.log`; `STAGING-ADAPTER-MANIFEST.json` captures exact uncommitted infrastructure files. Earlier 25-case logs remain dated baseline evidence. |
| v2 private R2 bucket | Created `snaglist-staging-private` in account `387d49014cd0d45f9e6434196ab513c0`, WEUR, Standard, default jurisdiction. Readback: managed domain `enabled:false`; zero custom domains. | `STAGING-PRIVATE-BUCKET.json`. Empty bucket; scoped application credentials/object-path acceptance still needed. |
| Independent candidate legacy-upload bucket | Created `snaglist-unified-staging-uploads` in the same account, WEUR/Standard. Readback: managed domain disabled; zero custom domains. | `STAGING-CANDIDATE-UPLOAD-BUCKET.json`. Candidate v1 writes therefore need not touch the existing recovery bucket. No public access enabled. |
| Pinned synthetic Neon DB | Read-only connection confirmed TLS, restricted non-superuser role, 53 tables and existing migration ledger. Project `dawn-queen-24474678`, database `snaglist_platform_test_0910222943_fc44`, host `ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech`. | `STAGING-DATABASE-READINESS.json`. No migration or application record written by this infrastructure task. This is retained review data, **not an empty database**. |
| Stable candidate secrets | Separate JWT and 32-byte base64 Contractor-link encryption key generated once in private local storage, retained with parent 0700/file 0600 permissions. | `STAGING-KEY-CUSTODY.json` records fingerprints only. No Worker secret installed or key rotation performed. Never upload the private configuration to Drive. |
| Google staging web client | Created **Snaglist web staging** in project `snaglist-508309`. Google success confirmation and client-list readback returned public ID `853801285577-3dmk0mtkjf9gcummuq374urgim0ohgp9.apps.googleusercontent.com`. Creation form had sole JavaScript origin `https://staging-app.usesnaglist.com` and no redirect URI. | Existing local web and iOS client preserved. No new scopes, client-secret download, production client or consent publication. Real staging sign-in not tested. |
| Existing native Google registration | Read-only provider page confirms client `853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0.apps.googleusercontent.com`, bundle `com.snaglist.app.staging`, Apple team `52ZZHYHM62`, callback scheme `com.googleusercontent.apps.853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0`. | Existing registration unchanged. Provider last-used timestamp is not proof of a successful native Snaglist exchange. |

Cloudflare's existing recovery container was read back as application `a036c64d-28f5-4d69-b6f0-aeedfcd4cb22`, image `registry.cloudflare.com/387d49014cd0d45f9e6434196ab513c0/snaglist-backend@sha256:85e618c7240bc9e1eb42d3dcddb348336ec4a6ea4993f07494f6c7727a0e4a89`, maximum one instance. Existing encrypted bindings and emitted workers.dev link origins remain unchanged (`STAGING-RECOVERY-BINDINGS.json`). The original customer upload/backup buckets were not modified.

An anonymous request to the newly disabled private managed domain did not resolve (curl 6/HTTP 000). This is reported only as observed DNS behaviour; it does not substitute for the API privacy configuration or an authenticated object test. The separate legacy-upload managed-domain HTTP check has not completed. A prior attempt was interrupted by usage-limit approval review and resumed after Dan's reset; it did not change provider state.

## Implemented infrastructure

Repository: `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`, branch `feature/unified-platform`.

- `Infrastructure/cloudflare/src/config.mjs`: new explicit `STAGING_DEPLOYMENT=unified-candidate` profile. It locks the pinned synthetic database/host, separate candidate bucket/account and candidate link origin. Recovery configuration remains unchanged; wrong profiles, origins, databases and buckets fail closed.
- `Infrastructure/cloudflare/scripts/prepare-build.mjs`: exports only committed Dockerfile, dockerignore, package pins, Sources and Tests from a reviewed hexadecimal commit. Refuses symlinks, uncommitted/other tracked content and overwriting a previous build directory; records paths/modes/bytes/SHA-256. No source copy from the changing shared warm package.
- `Infrastructure/cloudflare/scripts/candidate-config.mjs`: generates two **disabled** configurations from an immutable registry digest and absolute portal dist directory. Candidate backend name `snaglist-api-unified-staging`; no recovery or production custom-domain routes. Portal name `snaglist-portal-unified-staging`, with only `staging-app.usesnaglist.com`. No secrets or provider writes occur during generation.
- `Infrastructure/cloudflare/src/portal-proxy.mjs` and `src/portal.ts`: same-origin browser `/api/v2/*` through a service binding, preserving secure host-only session/challenge cookies, Origin, CSRF and binary request bodies. No write retries; errors remain errors. Unknown APIs and wrong-host Contractor routes cannot become SPA success pages. `run_worker_first:true` makes disabled/host guards precede assets. No arbitrary upstream URL or CORS workaround.
- `Infrastructure/cloudflare/test/candidate.test.mjs`, `portal-proxy.test.mjs`, `prepare-build.test.mjs`: exercised isolated candidate rejection, immutable export despite concurrent edits, symlink rejection, hostile Origin preservation, multiple secure cookies, binary upload bytes, disabled state, route separation and no write retries.

Root applied the infrastructure README update and public staging Google vars after reviewing the permission-boundary handoff. Both are now present in the repository. No unavailable provider is presented as verified.

## Coordinated candidate configuration

| Setting / surface | Required staging value / rule |
| --- | --- |
| Candidate API and Contractor `BASE_URL`, `MAGIC_LINK_BASE_URL` | `https://snaglist-api-unified-staging.danielmccann1705.workers.dev` — source/configured intent, not yet deployed or HTTP-verified |
| `PORTAL_ORIGIN` | `https://staging-app.usesnaglist.com` |
| `PLATFORM_ENVIRONMENT`, `GOOGLE_AUTH_ENVIRONMENT` | `staging` for both |
| `GOOGLE_WEB_CLIENT_ID` | `853801285577-3dmk0mtkjf9gcummuq374urgim0ohgp9.apps.googleusercontent.com` |
| `GOOGLE_IOS_CLIENT_ID` | `853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0.apps.googleusercontent.com` |
| iOS Google server audience | The new staging web client ID above, adopted alongside the verified candidate API environment. Keep iOS bundle/callback client unchanged. Root owns native changes. |
| Portal `VITE_CONTRACTOR_ORIGIN` | Candidate API origin above; relative activated `/m/c2_...` links must resolve there. Portal agent informed. |
| Browser API | Relative `/api/v2/*` on the portal host, service binding to candidate. Keep cookies host-only, Secure, HttpOnly and SameSite=Lax; preserve Origin/CSRF rather than rewriting them. |
| `R2_PRIVATE_BUCKET_NAME` | `snaglist-staging-private`, public access disabled |
| `R2_BUCKET_NAME` | `snaglist-unified-staging-uploads`, independent from recovery/customer storage |
| `R2_PUBLIC_URL` legacy configuration | `https://pub-d7c456d4b396462fb5ee8ef008dcf93b.r2.dev`, still disabled; do not claim v1 public photo compatibility |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | New credentials scoped only to both candidate buckets; not yet issued/installed. Do not broaden recovery credentials. |
| `DATABASE_URL` | Pinned review DB, TLS required, restricted role. Do not print credential value. No new DB/drop is authorised implicitly by capacity pressure. |
| `JWT_SECRET`, `LINK_GRANT_TOKEN_KEY` | Separate stable candidate private configuration. Install only as encrypted Worker secrets; never image args, source or reports. Retain link key across deploys. |
| `LINK_GRANT_TOKEN_PREVIOUS_KEY` | Absent unless an explicit documented rotation is in progress. Do not import the local review or production key as a convenience fallback. |
| Email | Candidate defaults disabled/no Resend key. If later tested, only existing approved sender `Snaglist <notifications@mail.snaglist.dev>` and Dan's authorised personal mailbox; no email sent by this task. |
| Purchases / push | Disabled in staging; no live billing or price changes. |

Google Workspace staff email is independent of customer Google sign-in. Its completed mailbox setup is not altered here. Google OAuth project consent previously recorded External/Testing; no publication performed. Native iOS production clients and other providers remain separate readiness work.

## Confirmed legacy-media compatibility limit before activation

The candidate managed URL `pub-d7c456…r2.dev` belongs to the new **candidate** legacy-upload bucket; recovery remains `pub-d03e874…r2.dev`. The mapping is correct, but the candidate bucket deliberately has public access disabled. `StorageService.publicBaseURL` still constructs historical public URLs. `UploadController.uploadPhoto` can upload and return those unusable URLs; `MagicLinkController.syncPhoto`/`syncDrawing` can persist relative paths and return success; `WebReportController.renderMagicLinkReport` prefixes the same origin for photos/plans. Thus v1 media/report compatibility is **not ready** on this private candidate. Merely changing `R2_PUBLIC_URL` to the API host cannot fix it because no equivalent authorised v1 object gateway exists. Opening a bucket would violate the current media isolation requirement.

A minimal candidate-only fail-closed patch from `work/unified-staging/candidate-legacy-media.patch` is now applied in infrastructure source by root; `src/index.ts` imports and calls the guard before the container fetch. It returns explicit HTTP 503 `legacy_media_unavailable_in_candidate` **before any backend/S3/DB write** for POST `/api/v1/uploads/photo` and POST `/api/v1/magic-links/:token/{photos,drawings,report}`. The message tells the tester to retain local evidence. It leaves recovery profile, v2 private media, native/provider auth and unrelated legacy management unchanged. Four targeted tests pass on the exact prepared helper, covering URI encoding/trailing separators, redacted response, unaffected recovery/auth/v2 and no false success. This is a staging safety guard, not production compatibility or a substitute for the native canonical media journey.

## Candidate credential preparation follow-up

Cloudflare connector account-token and permission-group reads return API 9109 (unauthorised); no token creation/update was attempted. Worker secret-name reads work, and the candidate still does not exist (10007). The authenticated task browser can show the account token UI. Its new-token form is prepared but unsubmitted: `snaglist-unified-staging-rw`, object read/write, only the two new candidate buckets and 30-day TTL. Recovery token remains scoped to `snaglist-staging-uploads`, expiring 9 October 2026. No public access or existing credential changed.

`work/unified-staging/prepare_candidate_secrets.py` safely assembles a future private Worker JSON from the pinned review connection, existing stable candidate JWT/link keys and the new R2 credential once issued. It checks exact account/buckets/DB/TLS, canonical distinct keys and bounded expiry, refuses overwriting differing prepared secrets, and never prints values or calls a provider. **Five safety cases pass**, recorded in `staging-evidence/candidate-secret-preparation-tests.log`. The actual R2 credential file does not yet exist, so secret assembly/installation have not run. The sequence documents exact encrypted `secret bulk` usage and requires remote disabled-candidate readback first because Wrangler can otherwise create a draft Worker automatically.

The pinned DB is mutable between checks: the backend graph agent reported that its local harness may have applied additive discovery/comment migrations after the earlier inventory. The backup runner checks the **actual** snapshot rather than assuming the dated 53-table inventory describes every later build.

## Remaining R0 gates, in order

1. Record the final infrastructure public config/docs checkpoint and its exact source digest. Obtain the backend graph agent's tested commit, export a **new** immutable build context and produce a matching Linux image using the already-warmed build layers; the a23fe3e image does not include newer sync work.
2. Image non-root/resources and bounded image-command smoke now pass. Still prove actual application startup/readiness/migration ledger and authenticated media routes against the candidate database without touching the graph runner's database.
3. Retained synthetic review backup/restore rehearsal now passes (53 tables, identical fingerprints). Recheck changes and take a current snapshot before applying final candidate migrations. Preserve local-session/capability/media provenance; create a new synthetic company/project through real APIs/UI. Existing local-media rows must not be counted as R2 evidence. Reserve runner DB `snaglist_platform_test_0911074529_fa3f` for backend tests; project already reached eight databases, so do not blindly create/drop.
4. Issue narrowly scoped candidate R2 credentials; install stable keys and exact env/provider bindings into the new disabled candidate only. Verify bucket privacy and actual authenticated original/processed upload/read plus anonymous/expired/revoked denial.
5. Push the tested image to the separate candidate registry repository, read back its immutable registry digest and deploy only the new candidate service. Preserve recovery image, routes and secrets. Generated image config requires a real registry digest, not a mutable tag or the assumption that a local manifest is already available in Cloudflare.
6. Build a matching immutable portal dist with the candidate Contractor origin. Verify the same-origin proxy/cookie/provider binding on `staging-app.usesnaglist.com`, then enable only the isolated candidate. Test Google web and native, PIN upload/submission/review and session/permission/conflict recovery with synthetic data.
7. Run the complete iOS → second manager → Contractor link → manager acceptance → original/fresh-device/report journey and D1/D2. R0 alone cannot close native sync or release acceptance.

No production routing, recovery replacement, registry push, Worker deployment, public bucket exposure, DB creation/drop, customer writes, email sends, paid upgrade, merge/push or App Store submission occurred in this infrastructure slice. Stable local secret custody still needs controlled deployment and recovery instructions before any go-live decision.

References: [Cloudflare Worker/asset routing](https://developers.cloudflare.com/workers/static-assets/routing/worker-script/), [asset binding configuration](https://developers.cloudflare.com/workers/static-assets/binding/), [service bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/). Provider API readbacks, rather than older documentation, establish the bucket and recovery state above.
