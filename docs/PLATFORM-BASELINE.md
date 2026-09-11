# Platform baseline — 10 September 2026, source checkpoint

## Current checkpoint — 11 September 2026

Backend application `7b4c8cd` now passes **226 tests, zero failures/skips**, on a fresh isolated Neon PostgreSQL 16 database; all eight workflow cases also pass independently. Portal `455c3e1` builds and passes **31 tests**. Actual browser review verified private before/after evidence, historical attempts, retained notes, accepted closure after reload and stale competing-decision rejection. A discovered no-op conflict button was replaced with a clear explanation and readable retained note. Responsive iframe widths 320/390/768/1024 showed no horizontal overflow; this is not physical-device or zoom acceptance.

The new synthetic-only Neon Free test project is separate from recovered staging. A restricted, endpoint-pinned runner leaves the original local-only guards unchanged. Interactive email is intercepted locally; no external message or production deployment occurred. Native full-build, canonical Contractor links, full sync, D1 recording/native PDF, real G1/D2 and remaining work packages stay open.

Dan also explicitly added Google sign-in on iOS/web and comprehensive company administration for Team plans. See [Google sign-in and team administration scope](https://drive.google.com/file/d/1uM-7BkQd8ID5btihXfoL9BAe1uE1FvUg/view) and the [connected review verification report](https://drive.google.com/file/d/127OOiTiWcKU904asY9rjpOB8-3c5Bu1O/view) for evidence, runtime boundaries and next dependencies. Earlier database-unverified statements below describe the 10 September checkpoint and are superseded by this executed verification; no whole package or release gate is complete.

Implementation follows the refreshed Google Drive unified-platform brief v1.1. The approved native reskin/icon, supplied Snaglistv2.zip identity, portal samples, contractor renderer and report work are preserved. This is a development candidate; no platform deployment or release occurred in this continuation.

## Reproducible source

| Repository | Working branch | Source checkpoint |
| --- | --- | --- |
| `/Users/danielmccann/Desktop/Projects/SnagLinkBackend` | `feature/unified-platform` | `7b4c8cd` |
| `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink` | `feature/unified-platform` | `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc` |
| `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal` | `feature/unified-portal` | `f763ae2` |

The source includes the verified identity/workspace/register foundation, private capture media, canonical completion workflow, history snapshots and transaction grouping. The full backend suite now passes on isolated Neon; connected browser review and its conflict correction are verified. These are local commits, not pushed, merged or deployed images.

Original bases were backend `022877e38bc19935e5ed8fdead7ea6215abb1916`, native `941b635ce2c1ddbc1b8ee72386d600d015c695a1`, portal `026014d2f36f49220652fbd8f993072ce0fa3a73`. Prior branches were not reset. `work/unified-platform/baseline/manifest.json` records the original status, binary diffs and source/asset archives before edits. The backend's unrelated local agent settings and duplicate staging-example file remain untracked and untouched. No credentials were committed in this milestone's scan.

The native checkpoint includes 90 changed/new files, most preserving earlier approved work. The bundled upstream font licence has one original trailing-space line; it was retained unchanged. Application-source whitespace checks pass.

## Build and test evidence

Backend `7b4c8cd` (workflow candidate; private-media base `6d742bf`); portal `f763ae2` (review candidate; private-photo base `1e8e387`); native `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`. Local branches only; no deployment/release.

**Verified locally:** private original/processed media, authenticated gateway, revisioned capture attachments, real portal photo upload/thumbnail/enlarge/reload. Backend full suite 218 pass before the last register-preview addition, then seven relevant cases pass; portal build and 31 tests now pass.

**Implemented but unverified in the database/browser:** canonical attempts, decisions, evidence consumption, reasoned waiver/internal fix/reopen, queued notifications, completion-history snapshots, transaction-grouped deltas and the connected review workspace. All backend application/test code compiles. The eight new workflow tests failed at database setup, so none is a workflow pass. The new review workspace still needs actual browser rendering/interaction inspection; the earlier connected-photo capture is separate evidence.

**Current blocker:** OrbStack/Docker's task database stopped responding and the OrbStack app shows setup requiring Dan's acceptance of its terms/privacy. A separate official PostgreSQL 16.15 source build succeeded, but the sandbox denied shared-memory initialisation. Neither path currently supplies a working test database. Existing databases/other projects were not reset. Native build still has its separate package-sandbox/CoreSimulator block.

See [WORKFLOW.md](https://drive.google.com/file/d/1x8NH7hxbBjoeyv65CUVfEuE-_iytKfZB/view) for architecture, exact file/symbol references, test labels and resumption instructions; [PRIVATE-MEDIA.md](https://drive.google.com/file/d/1h3md2ZhJ4rlrJdakMHsKEwTD0o36riEP/view) for upload/storage boundaries. D1 recording/fresh native PDF, real D2 and G1–G5 remain open. Earlier dated sections are historical checkpoints, not claims that later code passed their tests.

## Environment boundaries

The now-unresponsive original test runtime is `snaglist-platform-test-postgres` (PostgreSQL 16), only `127.0.0.1:55439`, disposable databases `snaglist_app_store_platform_identity` , `snaglist_app_store_platform_clean` and `snaglist_app_store_platform_browser`. The existing browser server was launched against that original test runtime and listens only on 127.0.0.1:55480; Vite uses 127.0.0.1:5176. Its DEBUG-only mailbox requires development mode, loopback origin/listener/database, the exact disposable browser database and an @example.test recipient; it is omitted from release compilation. Temporary mail links are kept in a private development directory and must never enter the evidence pack or Drive. There are no customer/provider credentials in the runner. Never aim it at a remote database.

The existing recovered synthetic staging Worker, Neon database, R2 storage and Resend sender remain the infrastructure baseline from 9 September. This milestone did not redeploy them or establish their current health. Production has not been cut over. Native remains version 2.0.0/build 2 in source; no new App Store Connect or installed public-version verification is implied.

Staging iOS uses distinct app/Clip bundles, SwiftData location, OS media/preferences/queue sandbox and Keychain service; production purchases/push/shared widgets are disabled. See `IOS-STAGING.md`. Account-specific partitioning within an installation remains WP-06 work.

## Evidence locations

Workspace root: `/Users/danielmccann/Documents/Codex/2026-09-06/her`.

- `outputs/app-store-prep/backend-tests/platform-fresh-schema-full.{json,log}`
- `outputs/app-store-prep/backend-tests/platform-exact-values.{json,log}`
- `outputs/platform/ios-staging-build.log` and `ios-staging-isolation-check.log`
- `outputs/platform/account-unavailable-desktop.png` (earlier connection-error state)
- `outputs/platform/connected-register-local.png` and `connected-register-conflict-local.png` (actual browser captures, synthetic API-created records)
- `outputs/app-store-prep/backend-tests/platform-register-full.{json,log}`, `platform-browser-mail.{json,log}`
- `work/unified-platform/local-review/manifest.json` (fixture scope, no credentials); `run.py`, `seed.py`, `mailbox.py` (local verification harness)
- `outputs/portal-design/index.html` and its actual capture files
- `outputs/platform/connected-register-private-photo-local.png` (actual successful photo upload before the database failure)
- `outputs/app-store-prep/backend-tests/platform-private-media-full-final.{json,log}`, `platform-private-media-preview.{json,log}`
- `outputs/app-store-prep/backend-tests/platform-workflow-current-build.{json,log}` (compile only); `platform-workflow-postgres16.{json,log}` (database setup failure)
- `docs/platform/WORKFLOW.md`, `docs/platform/PRIVATE-MEDIA.md`
- Backend `docs/api/openapi.json` (0.7.0-candidate, 42 paths / 54 operations / 60 schemas); portal `contracts/openapi.json` and `src/generated/apiTypes.ts`

D1 recording/fresh native PDF, D2 and G1–G5 remain open. A local test pass or source checkpoint is not proof of staging integration, customer migration or production readiness.
