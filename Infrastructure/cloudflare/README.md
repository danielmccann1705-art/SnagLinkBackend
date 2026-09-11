# Snaglist backend — Cloudflare staging

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

`npm ci` and `npm run check` validate the adapter. Use permitted temporary npm/buildx caches on this workstation. The locked package versions, Dockerfile and `.dockerignore` keep dependency and secret handling reviewable. Request headers, cookies, binary bodies and redirects are preserved; proxy identity is replaced with Cloudflare's client address. Responses use no-store/no-referrer/noindex headers. Persistent request/container logging remains disabled because old application log messages can contain bearer URLs.

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
