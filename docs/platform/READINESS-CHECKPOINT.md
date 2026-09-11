# Snaglist readiness checkpoint — 11 September 2026

**Outcome:** safety prerequisites are implemented and tested. The complete iOS/portal shared-project integration is still the first release blocker. No deployment, push, merge, App Store submission, production record or billing change occurred.

## Exact source and evidence

| Area | Current tested source | Result |
| --- | --- | --- |
| Native app | `feature/unified-platform`, `861b2f0` | Xcode Staging build and full suite succeeded: **167 passed, 0 failed, 5 skipped**, 172 total on iPhone 17 Pro / iOS 26.2. |
| Staging adapter | `feature/unified-platform`, `1585af1` | **15 adapter/proxy tests passed**, 0 failed/skipped; TypeScript check passed. Backend application code was not changed in this checkpoint, and no new full Vapor suite is claimed. |
| Portal | `feature/unified-portal`, `9c95ff7` (application `ae5c7f2`) | Fresh baseline build/API contract check and **59 tests passed**, 0 failed/skipped. Portal source unchanged this checkpoint. |

`READINESS-MANIFEST.json` records full commit IDs, paths, test limitations and evidence hashes. The final native bundle is `work/unified-platform/native-readiness-final.xcresult` in the shared Codex workspace; the portable summary is `IOS-TESTS-FINAL.json`. Modern xcresult summary extraction tried to write outside the permitted cache; the supported legacy object reader successfully extracted the copied result. This is a tooling limitation, not a test failure.

## What changed and why

- `Snaglist/Services/APIClient.swift`: injected test transport; authenticated requests bind to the local account generation before dispatch and after response/error/backoff. A → B → A is rejected too. Only GET/HEAD retry transient network/5xx errors with a bounded budget. Mutations are never blindly replayed after an uncertain outcome. HTTP non-success responses do not decode as acknowledgements.
- `ApprovalService.swift`, `ApprovalService+QueueActions.swift` and `APIClient+Approvals.swift`: personal snag decisions use the reviewed object's context and wait for the correct snag/status acknowledgement. Failure leaves the local review state unchanged. Duplicate in-flight review is guarded; changed local review state rejects a late response. Historical ownerless/revisionless queued approvals remain recoverable and require fresh review. No new such queue is created.
- `AuthManager.swift`, `AuthManager+MagicLink.swift`: restore token, valid backend UUID and activity metadata together; an orphaned token cannot silently authorise background calls while signed out. User creation uses the backend UUID directly instead of generating a fallback identity.
- `SyncManager.swift`, `Models/Enums.swift`: an empty legacy write queue no longer claims complete project sync or sets an invented last-sync time. The current local state says “On this device”. Complete graph sync remains to be implemented.
- `Debug/ReskinReview.swift`: synthetic approval fixtures now send the same ID/status/date acknowledgement as the actual API. Demo remains isolated from the network.
- `Infrastructure/cloudflare/src/config.mjs`, `wrangler.jsonc`: an explicit staging platform gate validates and forwards browser origin, platform environment, private media bucket, stable Contractor link key/rotation and optional separate Google web/iOS clients. Production/local origins, shared public media bucket, partial configuration and malformed keys are rejected. No secret values are embedded.
- New/updated regression tests: `APIClientReadinessTests.swift`, `SessionRestorationTests.swift`, `ApprovalServiceTests.swift`, `AuthManagerTests.swift`, `Infrastructure/cloudflare/test/config.test.mjs`. See those files for synthetic stimuli and assertions.

## Verification details

The new tests exercise lost write responses, 5xx, read retry limits, cancellation, stale responses on success/error/backoff, prepared requests after an A → B → A switch, raw-response session guards, malformed/expired restoration metadata, matching/incorrect review acknowledgements, denied/conflicting/offline review, retained legacy payloads and late account/local-state changes.

The first native run compiled successfully but had three failing acknowledgement tests because native stored aliases (`closed`/`rejected`) differ from server values (`approved`/`sentBack`). Matching through the existing status decoder corrected that error. Final run has zero failures. Five earlier approval test placeholders were replaced with executable persistence/transport tests. Five **AuthManager interactive** placeholders remain skipped; this is not evidence of actual provider/recovery success.

Two newly introduced actor-default warnings were fixed before the final run. One old warning remains in `MagicLinkSendManagerTests.swift` for a retroactive Equatable conformance. No global clean, simulator erase or package change was used.

## Important limits

These changes do not isolate the existing SwiftData/media store per account, implement a complete immutable outbox, restore all projects to a second device, or wire native canonical v2 close-out. A request-generation guard does not prove ownership of a model already visible before a request begins, and cannot roll back a server write that has committed. Old unversioned approvals need repair/re-review UI. The API's ordinary URLSession redirect behavior is unchanged; injected 3xx tests verify response handling, not a real redirect policy.

The staging configuration's names do not prove actual resource privacy, provider registration or delivery. Before enabling, provision/read back private R2 settings and credential scope, stable capability keys, isolated Neon/migrations, exact Linux image and same-origin staging portal proxy. Google group absence deliberately leaves Google unavailable. Apple/Microsoft, production adapter, account deletion/revocation, purchase/seat lifecycle, durable jobs, cleanup and report issuance still need the plan's implementation and acceptance.

The public website/business mailbox work, but public production API and portal go-live are not ready. Latest read-only checks are in `PUBLIC-SERVICE-CHECKS.json`: website/staging health 200, old production API 530, app domain unresolved at 15:26 UTC today. No newer production result is inferred.

## Next dependency-ordered work

1. Recoverable legacy device store/media backup and inventory, account/environment partitioning and explicit ownership/import resolution.
2. Full canonical graph/discovery and atomic immutable outbox, bounded pull/rebootstrap, stable IDs, conflict and access-removal repair; ordinary native capture must exercise it.
3. Matching Linux/Neon/private-R2 staging and portal proxy; real provider checks. Finish manager selection/assignment/Contractor link/archive UI while backend work proceeds.
4. Real two-manager native → portal → Contractor link → review → native/fresh device → report journey in `INTEGRATION-ACCEPTANCE.md`.
5. Remaining workbench/company admin, D2, durable reports/jobs, account lifecycle, test commerce/seats and operational/store evidence in `GO-LIVE-PLAN.md`.

No routine design approval or further mailbox setup is needed. Preserve all prior work and brand assets. A calendar release date follows the integration and data-migration gates; it is not justified by the local test counts alone.
