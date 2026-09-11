# Snaglist isolated staging — deployed, awaiting activation

11 September 2026, remote configuration read back at 19:28 UTC. **The isolated backend and portal have been deployed with application access disabled. R0 and go-live acceptance remain open.** No production/recovery route, customer storage, live billing or App Store release was changed.

## Exact deployed candidate

| Component | Verified checkpoint |
| --- | --- |
| Backend product | Frozen `91a53d97e47346bfe4c96da2378e0aac12927046`; Linux/amd64 image built, non-root resource/image-processing smoke passed, registry push acknowledged the same immutable digest. |
| Registry image | `registry.cloudflare.com/387d49014cd0d45f9e6434196ab513c0/snaglist-unified-staging@sha256:11b2587710a73da3c7dc3dff0e6e29b4b4a62d2ef698c6eaf7c850b5017128dc`. |
| Backend Worker | `snaglist-api-unified-staging`; deployment `5644941b138746b08560d3acfdac2b14`; `STAGING_ENABLED=false`, email disabled, no encrypted secret bindings installed. |
| Container application | `a0305da9-549f-46e7-b8e5-450411bacf92`; exact image above, private networking, WEUR, maximum one instance, 0.25 vCPU/1 GiB/4 GB, logs disabled. Latest scheduler metadata reports `instances=1`, `health.active=0`, `health.healthy=1`; this is **not proof that Vapor started or migrated its database**. |
| Worker adapter | Immutable `ffc5f90`, Wrangler 4.131.1; 29 adapter tests/typecheck passed. Backend and portal bundles came from the recorded dry runs. |
| Portal product | Frozen `e2507654300592329f018031dd3f66c0feec2aa6`; build and 74 tests passed. All 14 files were rechecked against the existing SHA-256 manifest before Cloudflare asset upload. |
| Portal Worker | `snaglist-portal-unified-staging`; deployment `829eaba6b2c74fcc9bbba7556f632a13`; `STAGING_PORTAL_ENABLED=false`, assets bound, exact service binding to the new backend, workers.dev and preview URLs disabled. |
| Staging domain | `staging-app.usesnaglist.com` created and read back as belonging only to the new portal Worker. Domain ID `9e2c0348a53fa18bdaf98597dc693fffca9de0ac`. No production hostname was reassigned. |

Cloudflare's returned `environment: production` means its default Worker namespace. These are explicitly staging-named services with staging application settings and the staging hostname; it does not mean the Snaglist production application was released.

The current working repositories are newer than this frozen deployment. Backend project metadata/assignment history `2c4fe4c` and portal comments/current v0.12 contract `a4bd706` are **not** in these deployed products. Refresh both frozen candidates together after their next complete tested milestone; do not copy a changing working directory into the recorded image or dist.

## What is and is not verified remotely

Configuration, bindings, domain ownership and pinned container image were read back through the authenticated provider API. An earlier backend `/health` request at 19:13 UTC returned the intended **503 “Snaglist staging is awaiting configuration.”**

The subsequent Python HTTP checks at 19:24 UTC returned **403 / Cloudflare error 1010** for backend health, portal home and portal API. These were edge-block responses, not application responses. Browser navigation to the portal also reported `ERR_BLOCKED_BY_CLIENT`, so browser accessibility and real rendered interactions remain unverified. A read-only zone check found `browser_check=on`; no firewall/security setting was weakened and no alternate-browser bypass was attempted. Cloudflare documents error 1010 as a browser-signature block: [official error reference](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/).

No database connection, migration ledger, application readiness, R2 object flow, real provider exchange, PIN submission, manager acceptance or native sync has been established on this remote candidate. A healthy scheduler count, upload receipt or unit-test pass cannot substitute for those checks.

## Deployment mechanics and custody

The existing Wrangler OAuth session could not refresh. Deployment used the already connected Cloudflare account API; no new persistent account credential was created. A provider-issued **15-minute managed-registry push/pull credential** was passed through a disposable private Docker configuration, then deleted. Docker's initial host-keychain failures were resolved by explicitly selecting that disposable file store. Global Docker credentials were not changed.

The portal used Cloudflare's documented direct asset upload: a short-lived upload session, three provider-selected buckets containing 5/5/4 files, then the completion receipt in the Worker upload. The helper rechecked each exact frozen file; MIME types and worker-first SPA routing were retained. Upload/completion JWTs are private transient deployment material and must never be copied to Drive. [Cloudflare direct upload documentation](https://developers.cloudflare.com/workers/static-assets/direct-upload/).

The optional new-runtime image-preparation endpoint returned `new_runtime_enabled is not enabled for this account`. No account feature flag was changed. The existing Cloudflare container application path accepted the immutable image and default scheduler configuration. This distinction is recorded rather than treating the failed optional preparation call as successful.

## Activation dependencies, in order

1. Obtain the pending action-time confirmation for the prepared **30-day object read/write credential, limited to `snaglist-staging-private` and `snaglist-unified-staging-uploads`**. Save it privately and install it only on this new candidate. Recovery credentials and bucket exposure remain unchanged.
2. Run the prepared bucket/privacy checks and private secret assembler. Install the exact pinned review `DATABASE_URL`, stable candidate signing/link keys and new bucket credentials as encrypted Worker secrets. Never regenerate the link key on a routine deploy.
3. Recheck/restore-test the retained synthetic review database before applying candidate migrations. Its existing review rows are not an empty database or proof of new R2 uploads. Preserve the separate graph test database.
4. Establish actual application startup/readiness and the migration ledger. Verify unauthorised/private/expired/revoked media denial and authenticated original/processed upload/read. Legacy v1 public-URL upload routes intentionally fail before writes on this candidate; native compatibility is still open.
5. Resolve legitimate browser access on the staging address without bypassing browser policy or weakening the whole domain. Verify the same-origin session/challenge cookies, CSRF, exact provider origins and service binding before enabling the isolated portal.
6. Verify real web/native provider round trips and the complete ordinary native → second manager → Contractor link → evidence → acceptance → native/fresh-device/report journey, then D2. Only a complete candidate can proceed to production disposition.

## Evidence and continuation files

- [Redacted deployment manifest](https://drive.google.com/file/d/1pqrk7mpr7evmR78vy12sdE_ivzP8XOfc/view), [provider configuration readback](https://drive.google.com/file/d/1ih9-czkjSs7mUqJxC45zdY8S4WQI0krg/view), [HTTP limitations](https://drive.google.com/file/d/19N_sgyMjxkWPo4DP3y3KV0O8mOzHtZDu/view).
- [Image build manifest](https://drive.google.com/file/d/1eqoObOlvSPYcWsVKrlaZIHeWnIMStuGm/view), [registry push](https://drive.google.com/file/d/16Bz5PsVjkCRoPrGf12bh8DJ4UZqipc22/view), [portal build/file manifest](https://drive.google.com/file/d/1BTWR-SErkO0QzW1soOg5Q0tzUUzTR9Df/view), [asset-upload receipt](https://drive.google.com/file/d/1_ZME_epAGSX2ABR6cVBtB7hAychhfyKf/view).
- [Ordered deployment procedure](STAGING-DEPLOYMENT-SEQUENCE.md), [preparation history](STAGING-IMPLEMENTATION.md), [go-live gates](GO-LIVE-PLAN.md).

Workspace deployment helpers are under `work/unified-staging/`: `push_verified_candidate.py`, `upload_portal_assets.py`, `prepare_candidate_secrets.py`, `check_candidate_r2.py`, immutable exports and generated configs. Only redacted reports belong in shared documentation; private configuration and database/recovery archives remain local.
