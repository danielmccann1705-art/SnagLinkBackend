# Native device-scope coordinator — tested app-target foundation

## Current integration checkpoint — 11 September, 20:19 UK

The coordinator and its tests are now part of the actual native target at `339203a2b2a8069918496205f6cef745cc719397`. The GUI Xcode staging build and test run passed **331 tests, zero failed, five existing skips** (336 total), including 21 coordinator cases. [Exact test evidence](https://drive.google.com/file/d/1NEft9gPGqJtYARdzQnzjkDT1FWjt8GOl/view). This authoritative result supersedes the earlier standalone-only integration limitation below.

**No live account switching is activated.** App composition, AuthManager, real ModelContainer/media/preferences, task draining and explicit legacy ownership still need the concrete adoption described below. The coordinator is a tested injected lifecycle boundary; it does not itself move, import, claim or delete customer records. Preserve this distinction in release reporting.

## Original preparation record and adoption plan

11 September 2026. Prepared for the root build agent. Native repository `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink` (`F` below), branch `feature/unified-platform`; latest observed clean HEAD `ba10346edbf197a98e28b5d6535eddf204a39356`. Workspace `/Users/danielmccann/Documents/Codex/2026-09-06/her` (`W`). Root owns current App/Auth/media/PBX work and Xcode verification.

## Assessment and status

A tested scope-switching foundation is ready for review/application. It does **not** open, move, migrate, claim, delete or switch any real SwiftData store, change auth, register services, or alter production files. Native account isolation remains incomplete until the concrete consumers below adopt this boundary. Existing preservation, subscription, push and Contractor link revocation safeguards must remain intact.

The actual app still opens one launch-long `ModelContainer` before auth, retains global media roots, and lets several singleton services retain its context. Replacing the container alone would therefore leave account-crossing callbacks and file lookups. The next complete milestone must include container, tasks, media, preferences and UI lifetime together, with a distinct read-only legacy route.

Prepared files (only the first two belong in F):

- [DeviceScopeCoordinator.swift](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/native-scope-coordinator/Snaglist/Services/DeviceScopeCoordinator.swift)
- [DeviceScopeCoordinatorTests.swift](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/native-scope-coordinator/SnaglistTests/DeviceScopeCoordinatorTests.swift)
- [Two-file patch](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/native-scope-coordinator/device-scope-coordinator.patch), checked with `git apply --check` against F; not applied by this agent.
- [Verification JSON](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/IOS-SCOPE-COORDINATOR.json) and [test log](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/native-scope-coordinator-tests.log).

`work/native-scope-coordinator/Package.swift` is a standalone verification harness. Its copied `DeviceDataScope.swift` is the exact prior foundation dependency, not a second source to apply. No PBX entry or live consumer was changed. No credential/browser action was taken.

## Implemented boundary

`DeviceScopeCoordinator<Resource>` is an observable MainActor state machine. Its injected `DeviceScopeLifecycle` receives a `DeviceScopeResource` whose scope/access must be immutable. The coordinator holds runtime bundles privately and exposes a bundle only for a currently valid `DeviceScopeLease`.

- `transition(to:) async -> DeviceScopeTransitionOutcome`: explicitly select an account, stable guest or unclaimed legacy scope. Concurrent requests are serialised; only the latest request can publish. A same-account remount still receives a fresh lease.
- `activeLease`, `isCurrent(_:)`, `canWrite(using:)`, `resources(using:)`: check device mount identity. Capture the lease **and** current auth/API generation before asynchronous work, then recheck before every result write/presentation. A retained object reference never extends its lease.
- `state`: `unopened`, `transitioning`, `ready`, `suspended`, `blocked`. Transition/cancellation/failure expose no old resource through the public access API. Failure reports a stage and preserved scope, not arbitrary database/network error text.
- `DeviceScopeResource.access`: unclaimed legacy must be `readOnly`; account/guest must be `readWrite`. This describes a device mount, not permission to call server APIs. Actual read-only enforcement and ownership verification belong to the factory; a label alone is insufficient.

For an existing mount, the enforced order is:

1. Invalidate its lease and hide the old view state immediately; invoke synchronous `freeze` exactly once.
2. Await `drain` so no task can continue writing through old references. On failure, retain the hidden resource and block; do not open the requested destination.
3. Save the quiescent writable context. Unclaimed legacy is never saved. Once drained, old writable work is still saved even if the transition was cancelled/superseded; save failure retains the context for retry.
4. Asynchronously `prepare` the explicit destination without global binding. If this result is late, release its runtime handles before preparing the newer request. It never becomes active.
5. Validate returned scope/access and reject the retained handle being returned as a supposedly fresh destination. Preserve the old resource on validation failure.
6. Atomically settle cancellation versus commit, release old runtime handles, publish a fresh lease and synchronously `activate` the new resource. No suspension occurs in this final step.

`release` means dropping/closing runtime resources only; it must never delete persistent files. A thrown preparation owns cleanup of its unpublished handles and must keep all durable data. The coordinator has no file deletion/import/claim API. It cannot enforce what a faulty lifecycle adapter does internally, so adapter tests remain required.

Only a tiny `OSAllocatedUnfairLock`-protected cancellation/commit decision crosses executors. It stores an enum, contains no resource or callback, and never spans an await. This avoids a cancellation/prepare-completion race caused by an asynchronous hop to MainActor. All actual lifecycle work remains serial on MainActor. Cancelling a caller does not cancel the cleanup worker; injected operations must have their own bounded cancellation/timeout policy and return or throw. The coordinator will stay hidden rather than overlap unsafe lifecycles to bypass a stuck task.

## Verification and limits

The final standalone run passed **17 Swift Testing functions / 21 cases across two suites**, zero failures/skips, on synthetic in-memory lifecycle resources. Tests cover:

- guest identity, genuinely separate account selection, read-only legacy, rejecting a writable legacy facade;
- freeze/drain/save/prepare/release/activate ordering and immediate stale-resource denial;
- A → B → A and same-account remount lease invalidation;
- drain/save/prepare failures with preserved handles and explicit retry;
- wrong scope, wrong access and reused-handle rejection;
- latest-request-wins during drain and during preparation, intermediate queued selection removal, late result disposal;
- cancellation during preparation, cancellation of the newest queued request, a pre-cancelled caller and an obsolete preparation error;
- atomic cancellation-before-commit, cancellation-after-commit and concurrent decision exclusivity.

Both standalone targets use Swift 5 language mode with default MainActor isolation, `-strict-concurrency=complete` and `-warnings-as-errors`. The final log contains two SwiftPM infrastructure warnings that per-user configuration/security cache directories are inaccessible; there are no source compiler warnings or test failures. The harness uses task-local build/cache/module directories and `swift test --disable-sandbox` for compiler subprocesses.

Auxiliary source-only iOS typecheck targeted `arm64-apple-ios17.0-simulator` against iOS Simulator SDK 26.2. The initial attempt failed because nested `sandbox-exec` could not launch the Observation macro plugin. One completed retry used the explicit compiler flag **`xcrun swiftc -disable-sandbox`**, which disables compiler subprocess sandboxing, and passed. Root subsequently instructed no further sandbox changes or retries; none were made. This result is **not** the app integration gate. Root's existing Xcode GUI build/tests are authoritative. The exact command/limitation is recorded in the JSON evidence.

No real ModelContainer, media, UserDefaults, Keychain, auth API, network service or database was opened by these tests. No physical-device/cold-relaunch/migration/UI integration has been established by this slice. The native source baseline was read while other agents were working; preserve newer root changes.

## Concrete integration patch plan

### 1. Resolve a scope without inventing ownership

Add a private installation ledger/factory ahead of live App opening. It should persist one stable guest UUID before first guest use, inventory actual existing store URLs from the existing configuration, and record unclaimed source fingerprints and recovery validation receipts. It must never derive legacy ownership from the next signed-in UUID, email, Apple relay address, profile row, defaults, purchase identity or an empty pending queue.

Construct `DeviceDataEnvironment` once from `AppConfiguration.environment` and its exact `API.baseURL`; no runtime environment selector. The current staging recovery origin and a future unified candidate origin are different scopes. Do not alias their data simply because both say staging. Canonicalise only trusted existing system roots (POSIX `realpath` for platform aliases), then use `DeviceDataStorageRoots` and `DeviceDataScopePaths` for every new account/guest path. Never canonicalise arbitrary model/import-relative paths to follow symlinks.

Resolve `.account(backendUserID:)` only from the existing validated backend session/response UUID. An authenticated user may open their explicitly owned new scope while the old unclaimed work remains separately preserved; an empty account store must say local/unsynchronised until canonical bootstrap completes. It must not masquerade as a migrated project collection. Sign-out requests the stable guest scope; it never exposes a previous account store.

For unclaimed legacy, prepare a dedicated read-only inventory/recovery facade. Do not hand ordinary edit-capable `RootView` an old ModelContext and rely on `canWrite` alone. Opening the original old SwiftData store with saves disabled is not evidence that framework migration/sidecars cannot write. Prefer a verified disposable recovery copy for any schema-dependent inspection, preserve the original source, and never launch legacy sync, default-trade seeding, deletion or revocation retry from that facade. Explicit future ownership/import review is separate work, not provided by this coordinator.

### 2. Implement the immutable native resource bundle

Create `NativeDeviceScopeResources: DeviceScopeResource` with `let` scope/access and immutable ownership of its ModelContainer (writable modes), path resolver, scope-specific Photo/FloorPlan services, preferences suite, task registry, export/cache locations and sync/outbox references. Read-only legacy can instead contain immutable inventory data; keep its container unavailable to the ordinary editing tree.

The factory must validate a durable scope manifest (environment/origin/principal/schema), reject mismatches and existing symlinks, create only the selected owned destination, and cold-reopen it before returning. It must not silently reset a corrupt existing store, adopt a different source, consume old queues or overwrite defaults. Reuse `DeviceModelSchema.current`, not a copied schema. New account scopes need a separate canonical-bootstrap state; store preparation success is not sync success.

### 3. Stage auth adoption and composition together

| Actual consumer | Required edit |
| --- | --- |
| `F/Snaglist/App/SnaglistApp.swift:8–63` (`modelContainer`, `init`) | Replace the launch-long optional container with a composition owner/coordinator. Remove unscoped launch tasks configuring SyncManager and seeding trades. Keep review/demo in-memory composition separate. Prepare account/guest/legacy resources before choosing the root UI. |
| Same, `.modelContainer(container)` / `RootView` | Mount the complete navigation/sheet/query tree under the new `lease.epoch`. Only ready writable resources get ordinary RootView and its container/defaults/services. Transitional/blocked states show neutral progress/recovery/error UI; legacy uses its distinct read-only route. An identity-keyed child prevents old queries, selection and sheets surviving into another account. |
| `F/Snaglist/Services/AuthManager.swift:33` (`checkExistingSession`) | Return/stage the existing validated token+UUID session instead of publishing `isAuthenticated`, assigning the shared API token and starting retries before the store is resolved. Do not weaken current orphan-token/inactivity checks. |
| Same `createOrUpdateUser`, Apple response handler; `AuthManager+MagicLink.swift:66` (`adoptAuthenticationResponse`) | Consolidate successful provider envelopes into an asynchronous adoption path: capture expected auth revision, resolve explicit scope, await transition, recheck auth revision/device lease, then atomically publish the matching account/token/profile and start account services. Failed/superseded adoption does not publish the new token. Google adoption must use the same final step. |
| `AuthManager.signOut:143` | Immediately invalidate auth and hide scope-owned content, preserve current push deregistration/subscription/revocation invalidation, request the stable guest scope, and keep a neutral screen if save/preparation fails. Never leave the previous account's store displayed. |
| `APIClient.swift:105–133` | Keep immutable environment and existing `sessionGeneration` checks. Bootstrap provider requests must not cause a new token to authorise old-store work. Prefer an isolated bootstrap transport or an explicit staged session; retain bounded requests and current generation checks. Device lease checks are additional, including guest/account and same-account remounts. |

`activate` should remain synchronous. A concrete composition adapter may synchronously publish the already validated staged auth envelope and bind its resources together; it must not start the new auth's consumers earlier. Every adopted result must still match the caller's auth revision. If that final adoption is superseded, immediately remain hidden/select the correct next scope. Do not use a ready local store alone as proof that the backend session remains valid.

### 4. Supply real freeze/drain/bind implementations

| Consumer | Exact scope work still required |
| --- | --- |
| `Services/SyncManager.swift:25–48`, `processPendingChanges:104` | The existing reconnect subscription starts tasks even though `stopMonitoring` only flips a flag. Add a lease-owned task registry, stop accepting new work, cancel/join tracked tasks, detach the container, clear published status, and rebind only in activate. Keep old contexts until drain finishes. Legacy `SLPendingChange` rows lack account/environment/revision provenance and remain quarantined; no automatic replay when merely mounting a store. |
| `Services/CommentSyncService.swift:22`, `ApprovalService.swift:23` | Explicit bind/unbind, tracked requests and post-await lease/auth checks before model writes. Preserve current rejection of unsafe old approval replay. Use canonical internal-comment/approval permissions when managed sync is added. |
| `Services/MagicLinkSyncService.swift:72,147,375,436` | Track snapshot/photo/report tasks and late results in the scope. Preserve the new owner/environment-bound private revocation queue and batch receipts; do not move them into ordinary preferences or replace them with earlier global queue code. Add device lease protection to model reconciliation/results. Never auto-share an unclaimed legacy scope or run legacy report snapshot sync for managed projects. |
| `MagicLinkSendManager`, `ShareLinkService`, `TeamService.currentTeam` | Freeze/dismiss old send/share state, callbacks and team model references. Clear published results on exit. Never reinterpret a retained model through the new account's resolver. |
| `App/SnaglistApp.swift:198–246` (`RootView` task, scene-phase, revocation handlers) | Capture lease and matching context before each operation. Gate background saves, refresh, queue processing and revocation reconciliation by the active writable scope. Track all async work; the read-only legacy root must not install these handlers. |
| `Services/WidgetDataWriter.swift:167` | Clear the published `widget_*` files and reload timelines during freeze; add/validate scope identity in new snapshots. Clear publication only, not private account data. Keep staging widget policy unchanged. |

`drain` is not equivalent to calling the current `stopMonitoring`, clearing an array, or cancelling a Task without joining it. Tasks may already have captured model objects and callbacks. They must either finish under their original frozen resolver with no new UI/model publication, or cancel and perform bounded cleanup before returning. Any uncertainty keeps the coordinator blocked.

### 5. Bind every media, preferences and recovery consumer

- `Services/PhotoStorageService.swift` currently uses global Documents/Photos; `savePhoto:96` recomputes the thumbnail root after an await. Inject a fixed resolver per resource, capture all output paths before suspension, keep partial cleanup within that captured scope and recheck the lease before model insertion. Do not mutate a singleton root.
- `Services/FloorPlanStorageService.swift` requires the same treatment. Correct the confirmed `Models/SLDrawing.swift:21–28` PhotoStorageService lookup versus actual FloorPlans persistence when updating callers. Preserve stored relative IDs/paths and verify each route.
- `Models/SLSnagPhoto.swift:36–104` and `SLUserProfile.swift:35–48` resolve through `PhotoStorageService.shared`. Replace convenience access with an explicit owning-scope resolver passed to capture/detail/annotation/export renderers, or a context-bound resolver. A retained old model must never consult whichever root is now active. Detached models without an owning resolver fail closed.
- Inject the resource's `UserDefaults(suiteName: paths.preferencesSuiteName)` into `MagicLinkSendSettings` and `TerminologyService`; current `@AppStorage` environment injection alone cannot fix their `.standard` reads. Classify installation settings separately (onboarding, OS permission facts); account/team data does not become installation-global for convenience. Recovery's preferences snapshot is a copy, not a second live settings store.
- `Views/Settings/SettingsView.swift:675–699`, `StorageUsageView`, exporters and report generators must use captured scope cache/media/temp paths. Cache cleanup cannot delete original/unsynchronised evidence or another account's files. Invalidate old preview/export/share URLs on transition.
- `Services/DeviceRecoveryCapture.source:87` already accepts documents/defaults. `Views/Settings/DeviceRecoveryCopyView.swift:59–86` must pass the captured resource roots/suite and check both device lease and API generation. Never silently copy all installation Documents after partitioning. Recovery/restore remain separate from claim/import.
- Preserve current subscription identity/cache and notification registration protections. A device scope is not a company entitlement, server role or invitation acceptance. APNs installation facts and account-specific registration remain distinct.

### 6. Integration acceptance before enabling real switching

Root should first register the new two files and run the existing Xcode native suite. Then add disk-backed adapter tests using temporary roots, the full existing schema and media bytes, without production stores. Required checks:

1. Existing legacy project/ID/photo/floorplan/queue/settings bytes remain unchanged after guest and account sign-in/out, refusal, cancellation, failed preparation and cold reopen. No implicit owner/claim or remote request occurs.
2. Account A → guest → B → A and same-account token refresh/relogin isolate queries, media URLs/thumbnails, preferences, tasks, widgets, export previews and subscription state. Canceled old tasks cannot insert/update/delete/present data in the new scope.
3. Interrupted media writes, full disk/save failure, corrupt destination, missing source/evidence, symlinks and auth change during preparation show an actionable blocked state and retain original data. Repeated retry does not duplicate imports or make an empty fallback.
4. Legacy read-only UI cannot edit/share/delete/submit or trigger lifecycle sync/seeding. An authenticated account's empty local store is distinguished from unclaimed work and from successful server bootstrap.
5. Ordinary capture/edit/recovery/Contractor link navigation remains usable in the correct scope; no safe-area, large-text or cross-account sheet regressions. Existing private revocation/subscription/session tests remain passing.

Only after this milestone should the canonical graph bootstrap, ownership-reviewed migration/outbox, second-device reconstruction and iOS → portal → Contractor link → accepted closure journey activate. The coordinator does not supply those capabilities.

## Source references

- [Earlier actual-consumer investigation](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/IOS-SCOPE-IMPLEMENTATION-NOTES.md) — its old global revocation-queue description is superseded by root's newer private queue work.
- [DeviceDataScope foundation and path guarantees](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/IOS-DEVICE-SCOPE-FOUNDATION.md).
- [Preservation/migration contract](/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink/docs/platform/DATA-MIGRATION.md).

Final source SHA-256: `8b9c76d6773481a01ef85c24937ff945955496a3523e6914a4bee5ef700918c3`.
Final tests SHA-256: `13d7fe4a38f9331cb2e0c538279c6bca7697f9825da648e4066d0e92a681634b`.
