# Snaglist — contractor link and close-out hardening

Updated 10 September 2026. This is a dated implementation addendum to the [9 September platform handover](https://drive.google.com/file/d/13s3JbrIVQ-Kug4P__gRZRhUZcK3JJwj_/view). It records the current build session, not a production release.

## Assessment

The current branches now contain fixes for ordinary iOS PIN publication, native revocation, direct contractor closure, stale review-state overwrites, snapshot-only approval replay and misleading browser completion labels. **46 distinct backend tests passed** against disposable local PostgreSQL 15. The actual browser-rendered status/count JavaScript and the extracted native publication acknowledgement types passed isolated checks.

The **full iOS build and device journey remain unverified**. Xcode's package diagnostics cache is not writable from this session; CoreSimulator refuses its service connection. A request for the required filesystem access returned no permissions. Swift syntax checks are not a substitute for an app build, SwiftData tests, simulator interaction or signed-device acceptance.

No production or staging deployment, source commit, merge, App Store upload/submission, price change or new portal was performed. Existing dirty work, branch names, customer storage and old records were preserved. Tests used a separate local container with synthetic records and no email/APNs/provider credentials.

## Source checkpoint

| Repository | Branch / unchanged HEAD | Starting state |
| --- | --- | --- |
| `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink` | `feature/brand-v2-project-snags` / `941b635ce2c1ddbc1b8ee72386d600d015c695a1` | 70 dirty entries before this slice |
| `/Users/danielmccann/Desktop/Projects/SnagLinkBackend` | `fix/cloudflare-backend-recovery` / `022877e38bc19935e5ed8fdead7ea6215abb1916` | 48 dirty entries before this slice |

HEAD alone still does not reproduce either candidate. Before editing, the session saved the Swift source/tests and project settings with hashes in `outputs/link-hardening/before/` and `baseline.json` under `/Users/danielmccann/Documents/Codex/2026-09-06/her`. `changes.patch` isolates this slice against those copies, including its new test file; `changed-files.json` records the 20 changed source/test files and hashes. That patch assumes the preserved dirty baseline and is **not** a standalone patch against Git HEAD. Existing binary brand assets were not altered in this slice.

## Changes and contract implications

### PIN publication

`MagicLinkSyncService.syncMagicLinkToBackend` sends the existing on-device PIN verifier and salt with metadata. `APIClient.uploadMagicLink` requires explicit `pinProtectionVerified == true` when the local link has a PIN, before uploading its report and media. A server that ignores the new fields cannot silently receive a supposedly protected publication from the updated path.

`PINVerificationService.importIOSHash` validates and tags the historical native `SHA256(PIN + salt)` representation, distinguishing it from the older backend `SHA256(salt + PIN)` format. Successful recipient verification upgrades the stored verifier to bcrypt. Republication preserves that stronger verifier. No plaintext PIN is added to the sync payload. This imports existing native storage; it is not a claim that the old local SHA256 scheme provides the protection of a password hash at rest.

New protected links from old clients that send only `hasPIN` now fail with 400 rather than becoming public. Ordinary unprotected old-client publication continues to work. Previously unprotected existing links can acquire their native verifier; already-protected links cannot be downgraded by synchronization. Wrong-owner upsert fails, and a link cannot be moved to another project or republished after revocation.

### Revocation

The backend now implements the actual native `POST /api/v1/magic-links/{token}/revoke` contract with authenticated creator ownership and a JSON success response. Repetition succeeds. Existing `DELETE /api/v1/magic-links/{serverUUID}` also succeeds when already revoked. The native service retains failed online revocations for retry, as it already did when known to be offline.

These checks revoke application link access. They **do not** recall downloaded copies or protect the existing public object URLs. Private media remains a separate platform/release requirement. Retry storage is still the existing device preference queue; complete account/environment partitioning remains outstanding.

### Contractor submission and manager review

The public status PATCH accepts only starting work (`in_progress`). Direct requests for `complete`, `completed`, `submitted`, `approved` or `closed` fail; submission uses the completion endpoint. A valid grant cannot mutate another owner's/project's canonical snag by supplying its UUID. Starting work preserves unknown fields in report JSON instead of rebuilding a reduced snapshot.

A project-scoped PostgreSQL transaction lock serializes the affected submission, review, report-publication and deletion operations. Submission checks current state and pending attempts across all links created by the same owner for that project. Competing submissions create one pending record; competing completion decisions produce one success and one conflict. Both manager review routes update canonical status and owned project snapshots. Reject/resubmit retains separate attempts.

For snags that exist only inside a shared report, the latest owned, project-scoped completion record now supplies review status during snapshot publication/read. A stale `open` snapshot cannot undo an approved report-only completion. No canonical record is invented as a side effect. This is interim protection, not general project synchronization or a full revision/conflict protocol.

Generic authenticated snag PATCH now rejects changes into or out of review-controlled states; ordinary field edits can still preserve an existing approved status and closed timestamp. **Compatibility consequence:** legacy manager clients attempting to close/reopen through generic PATCH receive 409 and must use a supported review command. This intentionally supersedes the old endpoint test that permitted `open → closed` there. Explicit manager-recorded fixes/reopening and versioned transition adapters belong in the larger workflow package; do not present this slice as complete compatibility for every legacy manager action.

The native completion rejection view also updates the linked local snag to Sent back. Native aliases treat `in_progress` as work sent/in progress and `complete`/`completed` as submitted, never as manager approval. The Clip permits a sent-back snag to be submitted again. These native changes have source/syntax checks but no current device pass.

### Browser and notification corrections

The contractor browser says **Submit for review** and **Submitted for review**, keeps pending work out of the approved count, and reserves the approved treatment for approved/legacy closed aliases. The printable HTML endpoint uses the same readable labels. It remains HTML, not a newly implemented PDF generator. Current local iOS reports are not made globally authoritative by this change.

The concurrency test exposed a notification lifecycle failure: an untracked completion notification Task accessed `req.db` after application shutdown. Completion notification attempts now finish within the request lifetime and catch/log failures after the completion is committed. This avoids that shutdown crash but can add notification latency to the response. Notifications remain best effort; no durable outbox or corrected team recipient routing was introduced. The known `DEFAULT_PM_EMAIL`/link-creator routing limitations remain.

## Evidence

| Check | Result and scope |
| --- | --- |
| `link-hardening-final` | 38 tests passed, zero failed/skipped; 10 September, 05:21 UTC approximately. Endpoint tests cover publication/PIN/revoke, scope, review races, report replay, deletion and account security; JSON records exact timestamps. |
| `link-hardening-legacy-status` | 8 additional distinct tests passed, zero failed/skipped, covering enum aliases and creation/update compatibility. |
| Browser state | Actual generated JavaScript parses and its status/count helpers pass in an isolated DOM stub. This is not browser end-to-end or accessibility verification. |
| Native publication contract | Six acknowledgement cases pass with the exact production response/error types extracted and compiled on macOS. This does not test URLSession or the app. |
| Native syntax | Changed Swift files parse successfully. Three XCTest methods were added but could not be run in iOS. |
| Full iOS build | Blocked during RevenueCat dependency processing: diagnostic file under `~/Library/Caches/org.swift.swiftpm` denied. CoreSimulator service also unavailable. No signed archive or new simulator screenshots. |

Earlier attempts are retained: one deletion fixture used byte-for-byte JSON equality and did not account for its own pending completion status; it now verifies preserved identity/content and status structurally. Another run accumulated public-link rate limits across cases; new cases now use separate synthetic proxy addresses, without disabling rate limiting. A subsequent concurrency run exposed the notification shutdown crash described above; the final run passed after the source fix. These failed attempts are not hidden or counted as additional passing cases.

Local evidence is in `outputs/link-hardening/verification.json`, `browser-state-check.json`, `ios-contract-source.json`, `ios-contract-check.log`, `ios-syntax-check.log` and `ios-build.log`. Detailed backend runs are in `outputs/app-store-prep/backend-tests/link-hardening-*.json` and `.log`. The test harness is `work/app-store-prep/run_backend_tests.py`; the JavaScript check is `work/link-hardening/check-browser-state.cjs`. All paths are relative to the Codex workspace given above.

Reproduction uses the existing isolated SwiftPM package copy at `work/reskin-next/backend-baseline`, with the current source/tests copied in and no dotenv files. The harness receives only local database, synthetic JWT and workspace cache configuration. A disposable `postgres:15-alpine` container was used on localhost port 55439, database `snaglist_release_linksv3`. The test container is removed after evidence capture; unrelated Docker services are left intact. To rerun, recreate that isolated test database and invoke the harness with the same filters from `verification.json`/the linked run summaries.

## Source map

Paths below are relative to the repository specified in the first column.

| Repository | Changed paths / symbols |
| --- | --- |
| Backend | `Sources/App/Controllers/MagicLinkController.swift`: `syncFromiOS`, `syncReportData`, `revoke`, `revokeByToken`, counts/print labels |
| Backend | `Sources/App/DTOs/MagicLinkDTO.swift`: native PIN input and publication acknowledgement |
| Backend | `Sources/App/Services/PINVerificationService.swift`: native verifier import/verification |
| Backend | `Sources/App/Controllers/CompletionController.swift`: start, submit, approve/reject, notification lifetime |
| Backend | `Sources/App/Controllers/ApprovalController.swift`, `SnagController.swift`: serialized review and generic PATCH protection |
| Backend | `Sources/App/Services/SnagWorkflowService.swift`, `SnagDeletionService.swift`: project lock, scope, snapshot-only status overlay, deletion serialization |
| Backend | `Sources/App/Models/SnagStatus.swift`, `Controllers/WebReportController.swift`, `Services/WebReportRenderer.swift`: display/count/action semantics |
| Backend tests | `Tests/AppTests/MagicLinkHardeningTests.swift` (11 new tests), `SnagDeletionTests.swift`, `SnagStatusBackcompatTests.swift` |
| iOS | `Snaglist/Services/MagicLinkSyncService.swift`, `APIClient+MagicLinkSync.swift`; `Models/Enums.swift`; `Views/Completions/CompletionReviewView.swift` |
| Clip | `SnaglistClip/Views/ClipSnagDetailView.swift` |
| iOS tests | `SnaglistTests/SnagPersistenceTests.swift` (three new test methods; iOS execution blocked) |

## Remaining work and next engineer instructions

Do not redeploy the old handover image and assume it contains these fixes. No new deployment or production health observation was made for this addendum. The last established staging/production status remains the dated 9 September record; production routing and App Store submission are still open.

1. Restore supported Xcode/package/simulator access, build the actual iOS and Clip targets, run relevant XCTest, then test native-created PIN links, revoke/reconnect, reject/resubmit and approved-state refresh against an isolated backend. Test publication failures before sharing URLs and account switches during queued work.
2. Checkpoint the complete dirty candidate with required assets/dependency locks, review secrets, and tie the next staging image to that exact source. The local patch is a preservation aid, not a deployable Git commit.
3. Keep identity recovery, backend account deletion/Apple revocation, purchase restoration and old-installation continuity as release gates. Public media, weak referenced-resource checks outside the patched workflow, account partitioning, optional evidence and best-effort notification routing are not solved by these 46 tests.
4. Reconcile this addendum with the incoming unified-platform plan. Reuse these fixes and tests; replace interim project/owner and snapshot mechanisms through the versioned workspace/workflow/sync design. Do not overwrite the reskin/recovery candidate or change live pricing while doing so.

This slice introduces no new data migration. It also does not restore lost server accounts/links, add general two-way synchronization, team membership, mandatory after-photo processing, private media or a manager portal. Those remain explicit platform work.

## Published milestone references

- [Implementation addendum](https://drive.google.com/file/d/1od4c-_HYDnfhGSE3lk78p9qZgzmVh9dt/view)
- [Platform plan review](https://drive.google.com/file/d/1775_fVSrTRYj3zrjOvwuoL6ZkL_fbtb2/view)
- [Verification and source hashes](https://drive.google.com/file/d/1WpYVFUBxw3mWUt7DG7U3nV215DZawJWT/view)
