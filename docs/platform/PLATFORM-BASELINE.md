# Platform baseline — 10 September 2026

Implementation continues under Drive brief v1.1, refreshed this turn. The existing approved native, portal, contractor and report design work is retained.

## Preserved candidate

`work/unified-platform/baseline/manifest.json` records archives, hashes, Git status and complete tracked diffs captured before new edits. The archives include tracked/untracked application source and assets, excluding credentials, local agent settings, caches and dependency builds. Backend: 166 files; iOS: 263; portal: 34.

Backend now uses `feature/unified-platform`, based on 022877e with the dirty recovery candidate retained. iOS now uses `feature/unified-platform`, based on 941b635 with the reskin/recovery candidate retained. Portal remains `feature/unified-portal`, starting from 026014d. Neither app/backend HEAD alone reproduces the dirty working candidate; use the source manifest/archive until the milestone commits are recorded.

## Environment evidence

Backend test runner uses a named disposable PostgreSQL 16 container `snaglist-platform-test-postgres`, bound only to 127.0.0.1:55439, database `snaglist_app_store_platform_identity`. It has no customer/provider credentials. Real staging verification remains outstanding; older 403/1010/client-block observations do not prove an outage.

Xcode 26.2 (17C52) was identified. Filesystem access to the iOS Git metadata, SwiftPM/Clang caches and CoreSimulator files/logs was granted. The platform branch was then created successfully. Simulator services still fail with connection-invalid/connection-refused. A generic Simulator build also failed at dependency resolution with `sandbox-exec: sandbox_apply: Operation not permitted`. Evidence: `ios-baseline-build.log`. No Simulator was erased, no caches were deleted, and no application code was changed to hide this failure.

## Verification so far

- Identity integration: 31 passed, zero failed/skipped (11 new browser tests, 4 identity guards, 9 native email endpoint cases, 7 token/validation cases). Actual PostgreSQL, no email provider delivery.
- Project access primitive: 13 passed in this continuation before membership wiring.
- Combined identity/workspace run: 58 passed, zero failed/skipped. The earlier four recognition-test assertions caused by shared rate-limit state were corrected by isolating that test budget.
- Legacy-boundary rerun: 44 passed, zero failed/skipped, including three new company/upload boundary cases.
- Canonical write foundation: 10 new PostgreSQL integration tests passed, zero failed/skipped: concurrent retries, conflicting edits, explicit nulls, protected fields, cross-project IDs, archive/restore, contributor permissions and removed-member receipt replay. These are local API tests, not native integration evidence.
- After the additive canonical migration, the 13 legacy/workspace tests also passed.
- Register snapshot/delta tests: the canonical suite now passes 16 cases, including frozen pagination with intervening edits, expiry, removed/rejoined membership, archive events and rollback.
- Full backend suite: 188 passed, zero failed/skipped after correcting an existing optional-analytics-auth defect and an old test fixture that retained a feature flag between runs.
- Authenticated invitation preview: an additional scoped run passes all 11 workspace integration tests; the preview does not consume invitations or expose company names to the wrong recipient.
- Portal build and 11 checks pass after real sign-in transport, timeout/cancellation/conflict handling and account/invitation confirmation forms were added. Browser inspection confirms an honest service-unavailable state while no local backend is listening.

No platform deployment, production data change, merge, release or billing activation has occurred.
