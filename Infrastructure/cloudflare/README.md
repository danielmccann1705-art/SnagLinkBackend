# Snaglist backend — Cloudflare staging

## Isolated unified candidate — 11 September continuation

The existing recovery Worker/container and `staging-api.usesnaglist.com` remain unchanged. `scripts/candidate-config.mjs` prepares two **disabled**, separately named Worker configurations: backend `snaglist-api-unified-staging` and portal `snaglist-portal-unified-staging`. Candidate Contractor origin is `https://snaglist-api-unified-staging.danielmccann1705.workers.dev`; portal origin is exactly `https://staging-app.usesnaglist.com`. No production/recovery route is generated for the candidate backend. Neither configuration is a deployment or working-provider claim.

`STAGING_DEPLOYMENT=unified-candidate` selects the pinned synthetic database/host, independent legacy-upload bucket/account and candidate origin. Recovery configuration is unchanged. Database `snaglist_platform_test_0910222943_fc44`, host `ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech`, Neon project `dawn-queen-24474678`, contains retained local review records, **not an empty database**. A read-only check confirmed TLS, restricted role, 53 tables and its existing migration ledger. Back it up before applying candidate migrations; preserve local-media/sessions/link provenance. Use a fresh synthetic workspace and new R2 evidence for staging acceptance. Do not create/drop databases or touch the separate graph-test runner database blindly.

Two additive R2 buckets were created in the authorised account: `snaglist-staging-private` for v2 evidence and `snaglist-unified-staging-uploads` to keep candidate v1 writes out of recovery storage. Both returned managed-domain `enabled:false` and zero custom domains. Keep public access disabled. New object read/write credentials must be scoped to these two buckets only; recovery credentials are not broadened. Bucket privacy configuration alone does not prove authenticated application upload/read.

Google project `snaglist-508309` now contains **Snaglist web staging**, public ID `853801285577-3dmk0mtkjf9gcummuq374urgim0ohgp9.apps.googleusercontent.com`, created with sole JavaScript origin `https://staging-app.usesnaglist.com`, no redirect URI and no additional scopes. Set `GOOGLE_AUTH_ENVIRONMENT=staging`, `GOOGLE_WEB_CLIENT_ID` to that ID, and `GOOGLE_IOS_CLIENT_ID=853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0.apps.googleusercontent.com`. Existing iOS staging bundle `com.snaglist.app.staging`, team `52ZZHYHM62` and callback scheme are unchanged. Native server audience must change together with its verified candidate API origin. Actual staging Google exchange, production clients and consent publication remain unverified/unconfigured as applicable.

`src/portal-proxy.mjs`/`src/portal.ts` serve browser API requests through a same-origin service binding to the candidate. They preserve Origin, CSRF, binary bodies and multiple secure host-only cookies, do not retry failed writes or authorise hostile origins, and keep unknown API/Contractor paths from turning into SPA success pages. `run_worker_first:true` runs disabled/environment/host guards before static assets. Never use CORS wildcards or cookie Domain rewrites to mask configuration errors.

`scripts/prepare-build.mjs` exports one explicit reviewed hexadecimal commit to a **new** output directory, including only Dockerfile/dockerignore/package pins/Sources/Tests. It refuses symlinks and concurrent working edits, and records each path, mode, size and SHA-256. Invocation: `node scripts/prepare-build.mjs /absolute/backend REVIEWED_COMMIT /absolute/new-build-directory`. Run the Linux/amd64 Docker build from the exported `source` directory. Record source manifest, base-image digests, build log, local image ID and actual registry digest separately; product build is not a test run. Re-export after graph changes.

After a tested immutable registry image and portal dist snapshot exist: `node scripts/candidate-config.mjs sha256:VERIFIED_REGISTRY_DIGEST /absolute/immutable/dist /absolute/new-config-directory`. The generator rejects mutable tags and leaves both services disabled. It does not push, deploy, create a DB or install secrets. Stable separate candidate JWT/link keys have been generated once in private task storage (0700 parent/0600 file); install as encrypted Worker secrets, retain the link key across deploys, and document previous-key rotations. Never put credentials in image arguments, source manifests, terminal output or Drive. Keep local review and recovery keys separate.

Before activation: test the exact final Linux image and migrations; back up retained synthetic data; install scoped R2 credentials, stable keys and exact provider bindings; verify readiness/private media/unauthorised denial; then enable only the isolated candidate and portal for native+browser Google and Contractor PIN/evidence/review acceptance. Candidate email defaults disabled. Existing recovery email, production routing, customer buckets and billing remain unchanged. The build workspace `outputs/readiness/STAGING-IMPLEMENTATION.md` records execution evidence and open gates.

References: [Cloudflare asset routing](https://developers.cloudflare.com/workers/static-assets/routing/worker-script/), [asset binding configuration](https://developers.cloudflare.com/workers/static-assets/binding/), [service bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/). Use installed Wrangler schema to validate configuration.


## Current unified candidate configuration — 11 September 2026

**Implemented and locally tested; not deployed.** The adapter now has an explicit `STAGING_PLATFORM_ENABLED=true` gate. With it off, existing recovery configuration remains unchanged. Supplying platform settings without the gate, or an incomplete set with the gate on, fails closed.

Required additions are `PLATFORM_ENVIRONMENT=staging`, `PORTAL_ORIGIN=https://staging-app.usesnaglist.com`, `R2_PRIVATE_BUCKET_NAME=snaglist-staging-private` and a separately generated 32-byte base64 `LINK_GRANT_TOKEN_KEY`. Retain `LINK_GRANT_TOKEN_PREVIOUS_KEY` only during a documented key rotation. Never reuse JWT or production keys. The origin and bucket are intended staging resources; this source change does **not** provision them or prove bucket privacy.

Google is optional until configured as a complete group: `GOOGLE_AUTH_ENVIRONMENT=staging`, distinct registered `GOOGLE_WEB_CLIENT_ID` and `GOOGLE_IOS_CLIENT_ID`. These client IDs are public configuration, but actual environment ownership and callback registration still require provider readback. Other settings are never passed through implicitly. Current recovery link origins, approved Resend sender/sole test recipient and disabled purchases/push remain unchanged.

Before enabling: build/test the exact Linux application image, confirm isolated Neon migrations, provision the separate R2 bucket with public access disabled and scoped credentials, configure the staging portal's same-origin proxy/cookies, and verify real native Google + browser sign-in, private upload/read and Contractor link evidence/review. Preserve the stable link encryption key across deploys. No `wrangler deploy` was run for this change. Adapter/proxy regression suite: **15 passed, zero failed/skipped**; TypeScript check passed. Production needs a separately reviewed adapter after release gates.

## Historical recovery deployment — 9 September 2026

Updated 9 September 2026. A synthetic staging service is deployed at `https://snaglist-api-staging.danielmccann1705.workers.dev`. Production routing is unchanged. Existing uncommitted application changes are preserved on `fix/cloudflare-backend-recovery`; no commit, push or merge was made.

The owner approved Neon and a fresh database, explicitly waiving the old-data recovery search. Keep the existing R2 customer objects/backup intact. Never run cleanup against that old bucket. The current staging deployment uses Neon PostgreSQL 15 in London (`snaglist-staging`, default branch label `production`, database `neondb`) and one Cloudflare basic container in Western Europe. No paid-plan upgrade was purchased.

## Credentials and delivery

Database, JWT, R2 and Resend values are encrypted Worker secrets. They are absent from the source/image. R2 object access is scoped to `snaglist-staging-uploads` and expires on 9 October 2026. Resend sending access is scoped to verified `mail.snaglist.dev`. The adapter permits email only when explicitly enabled with sender `Snaglist <notifications@mail.snaglist.dev>` and sole recipient `danielmccann1705@gmail.com`, authorized by the owner. RevenueCat/APNs remain disabled in staging.

The photo bucket remains private pending explicit approval for public synthetic-image URLs. Uploads pass privately. The configured r2.dev hostname is not evidence that public access is enabled.

## Build and deployment

`npm ci` and `npm run check` validate the adapter. Use permitted temporary npm/buildx caches on this workstation. The locked package versions, Dockerfile and `.dockerignore` keep dependency and secret handling reviewable. Request headers, cookies, binary bodies and redirects are preserved; proxy identity is replaced with Cloudflare's client address. Responses use no-store/no-referrer/noindex headers, except successful portal HTML uses `strict-origin` so Google Identity Services can recognise its registered origin. This policy sends no path, query or token even to same-origin resources; API, Contractor, errors and non-HTML assets remain `no-referrer`. See Google's [identity setup guidance](https://developers.google.com/identity/gsi/web/guides/get-google-api-clientid#content_security_policy). Persistent request/container logging remains disabled because old application log messages can contain bearer URLs.

Deploy only a tested Linux/amd64 image by its immutable registry digest. Current product images use all application source files, checked by hashes; an earlier test snapshot is reused for the dependency-cache layer. Current regression tests run separately against disposable PostgreSQL. Tests are not packaged into the runtime image. Do not describe the cache snapshot as a current full test run.

The local Wrangler configuration remains disabled by default to prevent accidental deployment with incomplete values. Live nonsecret variables, image digest, resource identifiers, tests and outstanding work are recorded in the workspace's `outputs/backend-recovery/PROVISIONING-STATUS.json` and `STAGING-ACCEPTANCE.md`. Preserve all encrypted secret bindings during updates. No production environment or routes are included here.

## Production gates

Finish staging photo reads, browser and real-device paths, email inbox placement and existing-device/local-data/purchase compatibility. Provision production separately after acceptance. Replace process-only cleanup with durable scheduling, separate migrations from startup, add database readiness and redacted monitoring, and configure/test new database backups. These are outstanding work, not completed guarantees.

Preserve `api.snaglist.dev` and the apex website Worker. Route `/api/v1/*`, `/m/*`, `/link/*`, `/preview/*`, `/auth/*` and Apple association files deliberately; keep the marketing website. A fresh database cannot restore historical account IDs, links or completion history just by retaining the domain.

PIN enforcement, compatibility validation/PIN routes, concurrent sign-in consumption and completion/approval status synchronization were repaired during staging acceptance. The prior App Store handoff's account deletion/isolation, Apple revocation, subscription identity/refresh and moderation gates still apply. No App Store upload or submission has occurred.

## Sources

- [Cloudflare Containers GA](https://developers.cloudflare.com/changelog/post/2026-04-13-containers-sandbox-ga/)
- [Container lifecycle and ephemeral disk](https://developers.cloudflare.com/containers/faq/)
- [Container secrets](https://developers.cloudflare.com/containers/examples/env-vars-and-secrets/)
- [Cloudflare pricing](https://developers.cloudflare.com/containers/platform/pricing/)
- [Neon pricing](https://neon.com/pricing)
