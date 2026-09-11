# Matching Snaglist staging deployment sequence

## Execution status — 11 September, 19:28 UTC

The frozen `91a53d9` image has been built, smoked and pushed; the disabled backend Worker/container and frozen `e250765` portal Worker/assets/domain have been created. [Current deployment record](STAGING-CANDIDATE-DEPLOYMENT.md) provides exact source, image/deployment IDs and public-check limitations. Encrypted candidate secrets, actual startup/migrations, private media, providers, enablement and full integration are still pending. Do not repeat completed resource creation or overwrite the frozen exports.

The existing CLI OAuth refresh failed; the completed deployment used the authenticated Cloudflare connector and short-lived managed-registry/assets credentials. The pending persistent R2 credential has **not** been created. The procedural steps below remain useful for the remaining activation work, but their original “not deployed” observations are historical.

## Original preparation and procedure

Prepared 11 September 2026. This is an execution handover for the already authorised isolated candidate, **not a record of successful deployment**. Root owns the final export, matching image build and activation. The recovery Worker, production routes, customer buckets, prices and mail delivery must remain unchanged.

## Fixed scope and access observations

- Account: `387d49014cd0d45f9e6434196ab513c0`.
- Candidate backend: `snaglist-api-unified-staging`, intended origin `https://snaglist-api-unified-staging.danielmccann1705.workers.dev`.
- Candidate portal: `snaglist-portal-unified-staging`; only custom domain `staging-app.usesnaglist.com` in zone `524101d7172595a591bfcdec0c407c27`.
- New R2 buckets only: `snaglist-staging-private` and `snaglist-unified-staging-uploads`, both default jurisdiction, managed public access disabled and no custom domains.
- Neon: the pinned retained synthetic review database `snaglist_platform_test_0910222943_fc44` on `ep-solitary-union-zav239mi.c-2.eu-west-2.aws.neon.tech`, project `dawn-queen-24474678`. Do not use the graph runner DB or recovery `neondb`.
- Cloudflare connector reads confirm the candidate Worker does **not yet exist** (10007). Recovery secret-name listing succeeds; account-token listing and account-token permission-group reads return **9109 unauthorised**. No token mutation was attempted.
- The authenticated dashboard shows recovery token `snaglist-staging-uploads-rw` still scoped only to the old staging bucket, expiring 9 October 2026. No existing token was edited. A new-token form is prepared, not submitted, in task Chrome tab `1432436689`: `snaglist-unified-staging-rw`, Object Read & Write, exactly the two candidate buckets, 30-day TTL.
- Installed Wrangler's documented default local profile exists at `~/.wrangler/config/default.toml`. A redacted read shows OAuth and refresh material, recorded access-token expiry 3 August 2026, and Workers/containers scopes but no account-token management scope. This task did not refresh or alter global authentication. Root may have a separate task profile; use its actual authorised deployment configuration. Expired CLI access is not proof the dashboard session has expired.

## 1. Freeze matching source, build and record evidence

The current frozen image checkpoint is `91a53d97e47346bfe4c96da2378e0aac12927046`. Backend `2c4fe4c` now adds tested metadata and assignment history; it requires its own final image before claiming those features deployed. Do not mix or relabel these source checkpoints. Export this commit with `Infrastructure/cloudflare/scripts/prepare-build.mjs` into a **new** task directory; never copy the concurrent warm package or working Sources. Record `SOURCE-MANIFEST.json` and build-context SHA. The already completed `a23fe3e` image remains a baseline smoke result; it does not represent this newer source.

Build Linux/amd64 with the exact committed Dockerfile/package pins, a new unique tag such as `snaglist-unified-staging:91a53d9`, and a separate iidfile/log. Root should reuse Docker's layers, not restart the earlier baseline image. Record the new local index/platform/config digests. Run the existing bounded runtime smoke with explicit `--platform linux/amd64`; record non-root UID, contractor resources and image-processing result. Application startup and private media tests remain separate gates.

The first `91a53d9` attempt stopped before the build because Docker tried to write `~/.docker/buildx/activity`. The successful baseline used `BUILDX_CONFIG=/Users/danielmccann/Documents/Codex/2026-09-06/her/work/unified-staging/buildx`; root has been sent that existing task-directory configuration. Do not report the new build successful until its actual completion/digest is recorded.

The originally requested portal checkpoint was `84a5223354a6aa01d561e60b05f3e59392124b02`; root has now checkpointed the newer generated contract at `e2507654300592329f018031dd3f66c0feec2aa6`. Record the explicitly selected final portal commit instead of silently combining working changes. Build from the immutable export using its lockfile and `npm run build`/relevant tests. Set **only public** `VITE_CONTRACTOR_ORIGIN=https://snaglist-api-unified-staging.danielmccann1705.workers.dev`. Browser API paths stay relative/same-origin. Google configuration is read from the backend, not a guessed Vite client ID. Archive the actual dist hash and source reference.

Before activating application startup/migrations, rerun the bounded pinned-review backup/restore runner if the schema or data changed since `STAGING-BACKUP-RESTORE.json`. Existing backup rehearsal passed 53 table counts/fingerprints. It is a current retained synthetic snapshot, not a pristine schema claim. Do not restore a backup over the live review DB as a casual rollback.

## 2. Push only the immutable candidate image

Use the repository-installed Wrangler **4.131.1**, with account explicitly selected as above. The exact CLI supports `wrangler containers push snaglist-unified-staging:91a53d9 --path-to-docker /usr/local/bin/docker`. The local image must already have passed inspection. It pushes to a separate candidate image repository; do not retag the recovery repository. Record the returned registry URI and read back the remote digest. Never use the baseline local digest as evidence of remote availability.

Generate configs with `Infrastructure/cloudflare/scripts/candidate-config.mjs REMOTE_SHA256 ABSOLUTE_IMMUTABLE_PORTAL_DIST ABSOLUTE_NEW_CONFIG_DIRECTORY`. The generator refuses a missing/malformed digest and emits `backend.json`/`portal.json` with enable flags **false**. It requires the image under `registry.cloudflare.com/387d49014cd0d45f9e6434196ab513c0/snaglist-unified-staging@sha256:…`. If the registry output differs, resolve and correct the explicit candidate reference before deployment; never substitute a mutable tag.

Set `CLOUDFLARE_ACCOUNT_ID` to the fixed account in the executing process. Run Wrangler dry-run against these explicit configs, with bounded task output directories. Do **not** use `--env staging` or the repository's recovery `wrangler.jsonc`. Inspect the resolved Worker names, route list, one basic WEUR container, service binding and absolute asset directory.

## 3. Deploy disabled backend, then install candidate secrets

Deploy `backend.json` only, with `STAGING_ENABLED=false`. The backend has workers.dev enabled but no production or recovery custom-domain route. Read its settings back; record public vars and secret **names only**, container application ID, immutable registry image, and new Durable Object namespace. Verify `/health` returns the intentional no-store 503 awaiting configuration and does not start application DB work while disabled.

Create one new bucket-scoped R2 account token through an authorised account-token API or the prepared provider form. Do not broaden an old token, enable public buckets or select all-buckets/Admin access. The exact policy uses permission `Workers R2 Storage Bucket Item Write`, ID `2efd5506f9c8494dacb1fa10a3e7d5b6`, and only:

```json
{
  "com.cloudflare.edge.r2.bucket.387d49014cd0d45f9e6434196ab513c0_default_snaglist-staging-private": "*",
  "com.cloudflare.edge.r2.bucket.387d49014cd0d45f9e6434196ab513c0_default_snaglist-unified-staging-uploads": "*"
}
```

An account-token API creation response provides a one-time token value. Cloudflare documents S3 access key ID as token `id` and S3 secret as SHA-256 of token `value`. Derive/store it inside the credential-handling process; do not return either credential to tool output, tool arguments, reports or Drive. The API connector can run WebCrypto and add encrypted Worker secrets, but its current account-token permissions are denied; do not try increasing its permissions without specific need. Temporary R2 credentials are not a drop-in workaround: current Soto setup does not pass a session token, and temporary credentials are bound to one bucket. [Cloudflare R2 authentication](https://developers.cloudflare.com/r2/api/tokens/), [temporary credentials](https://developers.cloudflare.com/r2/api/s3/temporary-credentials/).

For the private local-file route, store `work/unified-staging/private/candidate-r2-credentials.json` in the existing owner-only directory (file 0600), with field names `accountId`, `buckets`, `permission` (`object-read-write`), `expiresOn` (UTC RFC3339), `accessKeyId` and `secretAccessKey`. Only independently observed provider scope belongs in this metadata. Run `work/unified-staging/prepare_candidate_secrets.py` using the bundled Python. Five safety tests pass for wrong account/bucket/DB/TLS/expiry/key separation. The helper reads the retained candidate keys and pinned private Neon config, assembles `candidate-worker-secrets.json`, refuses differing existing output, and emits only a redacted preparation manifest. It performs no remote write.

Immediately before installation, confirm the **existing** remote candidate is still disabled. Then run the installed Wrangler `secret bulk` with the absolute private JSON path, explicit `--name snaglist-api-unified-staging` and explicit candidate `--config …/backend.json`. Its input contains exactly `DATABASE_URL`, `JWT_SECRET`, `LINK_GRANT_TOKEN_KEY`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`; no null/deletion values and no Resend/purchase/push secret. Keep stdout/stderr redacted; never enable debug output. Wrangler's inspected implementation can create a draft Worker if missing, which is why the existence/settings check is mandatory before invocation. Read back only the five secret names and unchanged disabled vars after success. Do not regenerate JWT/link keys during redeploy or add a previous key without a documented rotation.

Before application activation, `work/unified-staging/check_candidate_r2.py` can verify the issued credential directly with the S3 endpoint. It requires HEAD access to the old recovery bucket to be denied with 403, without listing/reading any object there. It writes and reads only a fresh unique synthetic `readiness-probes/<UUID>.txt` in each candidate bucket, compares exact bytes and then deletes only those own probe keys and verifies 404. The hostname/account/scope are fixed, redirects refused, each network call limited to ten seconds, and the overall run bounded at 120 seconds. It emits redacted `STAGING-R2-CREDENTIAL-CHECK.json`; a cleanup failure retains the unique synthetic key for controlled follow-up. **Nine combined local safety cases pass** in `candidate-credential-safety-tests.log`. The real S3 run is pending token issuance and is not yet claimed as passed. This runner cannot replace the application's authorised media read/write tests.

## 4. Deploy disabled same-origin portal and verify bindings

Deploy `portal.json` with `STAGING_PORTAL_ENABLED=false`. Verify only `staging-app.usesnaglist.com` is routed, no workers.dev preview, service binding `BACKEND` targets the new candidate and assets are the immutable dist. The portal gate should return no-store 503. Preserve browser request Origin, CSRF headers and secure host-only cookies; the proxy intentionally does not rewrite hostile Origin or cookie Domain. No direct credentialed cross-origin browser API is needed.

Public candidate bindings already prepared:

| Setting | Value |
| --- | --- |
| `BASE_URL`, `MAGIC_LINK_BASE_URL`, portal `VITE_CONTRACTOR_ORIGIN` | Candidate workers.dev backend origin above |
| `PORTAL_ORIGIN` | `https://staging-app.usesnaglist.com` |
| `PLATFORM_ENVIRONMENT`, `GOOGLE_AUTH_ENVIRONMENT` | `staging` |
| `GOOGLE_WEB_CLIENT_ID` | `853801285577-3dmk0mtkjf9gcummuq374urgim0ohgp9.apps.googleusercontent.com` |
| `GOOGLE_IOS_CLIENT_ID` | `853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0.apps.googleusercontent.com` |
| Native SDK `serverClientID` | This same staging web client; root binds it with the verified candidate API origin |
| Native callback scheme | `com.googleusercontent.apps.853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0` |

Native bundle is `com.snaglist.app.staging`, Apple team `52ZZHYHM62`. The web provider registration has the sole staging portal JavaScript origin and no redirect URI. Real native/web provider exchanges remain an acceptance task; local Google success or a client-list entry is insufficient.

## 5. Activate and prove the isolated journey

After backup, migrations review and encrypted configuration, enable the candidate backend only. Read actual readiness/migration ledger from the exact image, then enable the portal. Application startup can apply additive migrations to the pinned review DB, so this is the migration boundary. Record versions and time. Do not reuse old local-media review records as R2 proof: create new coherent synthetic company/project evidence via supported authenticated APIs/UI.

Prove private original upload, processing, retrieval, browser/canonical snag attachment and report access. Also prove anonymous, other-company, expired/revoked-link and invalid-PIN denials without logging link tokens. Verify contractor link activation resolves to the candidate backend origin; submission/awaiting review/accepted closure are distinct. Check portal login cookies, hostile Origin/CSRF rejection, real Google web/native sign-in, native pull/outbox/conflicts, manager acceptance and fresh-device/report readback. Keep synthetic mail disabled unless separately exercising the previously authorised Dan-only sender workflow.

The candidate-only compatibility guard now present in source returns explicit 503 on legacy photo/drawing/report snapshot uploads before writes. This is intentional: legacy public URLs cannot work against a private bucket. It is **not** a pass for older native media upload or old issued-link compatibility. Do not enable public R2 or declare app/portal parity to bypass this gap. Native canonical media integration or a properly authorised compatibility gateway remains required before go-live.

## Stop/rollback boundaries

On a candidate failure, disable the candidate portal/backend enable flags and preserve logs with identifiers redacted. Keep existing recovery unchanged and keep immutable candidate images available for diagnosis. Do not delete a registry image needed by a previous deployment. For additive schema changes, preserve current DB state and investigate a forward repair; restoring over shared review records needs a specifically reviewed target/cutoff. Credential expiry is a maintenance item: record the actual provider expiry, arrange bounded renewal before it, and never silently reuse the recovery credential.

Deployment success requires remote version IDs, image digest, domain/service-binding/settings readback and exercised behaviour. A build, dry-run, prepared form or encrypted secret-name list alone does not close R0. [Cloudflare image management](https://developers.cloudflare.com/containers/guides/image-management/).
