# Native device-scope foundation

## Root integration checkpoint

Committed at native `ba10346edbf197a98e28b5d6535eddf204a39356`. The source and tests are registered in the real app/test target. Xcode Snaglist Staging build and test succeeded for the 19:51 UK run: **275 passed, zero failed, five existing skips**, 280 total. This includes all 49 new scope/path cases. The sole warning remains the existing test-only Equatable extension. Source hashes below are unchanged. See `IOS-DEVICE-SCOPE-FOUNDATION.json` for the exact result bundle.

This implements scope identities and validated path plans only. The app still opens its existing store; live store/media/account partitioning and explicit legacy import remain open. No file or project was claimed, moved or deleted.

## Original agent handover — preparation state

11 September 2026. This implements a bounded R1 foundation, **not complete account isolation or native synchronisation**. Prepared against native `feature/unified-platform`, last read HEAD `6e751fa9cbb7625e11c1f2784f3a16b46395bbb9`. Root's App/Auth/link/UI/PBX work was preserved. This task changes no existing app source, SwiftData configuration/schema, production store, media, preferences or Keychain. No credential/provider work continued during this slice.

## Deliverable and verification

Prepared source: `work/native-scope/Snaglist/Services/DeviceDataScope.swift` → repository `Snaglist/Services/DeviceDataScope.swift`.

Prepared tests: `work/native-scope/SnaglistTests/DeviceDataScopeTests.swift` → repository `SnaglistTests/DeviceDataScopeTests.swift`.

Both are also supplied in `work/native-scope/device-data-scope.patch`. Root owns applying them and registering the source in the existing PBX project. Do not copy the verification-only `work/native-scope/Package.swift` into the app repository.

- **16 Swift Testing functions / 49 independent cases passed**, zero failures/skips, in the task-local no-dependency Swift package. It uses Swift 5 mode, MainActor default isolation for the source module, complete strict concurrency and warnings-as-errors. Every filesystem fixture is a unique temporary directory.
- **iOS simulator SDK typecheck passed**: arm64, iOS 17 deployment target, Xcode iPhoneSimulator26.2 SDK, Swift 5, MainActor default, complete concurrency and warnings-as-errors. This is an SDK compile check, not an app build or simulator workflow test.
- Logs: `outputs/readiness/native-scope-tests.log`, `native-scope-ios-typecheck.log`; exact source/test hashes: `IOS-DEVICE-SCOPE-FOUNDATION.json`.
- Construction/resolution tests assert no new scope directories or stores are created. Existing synthetic legacy bytes remain unchanged. Tests cover A/B, guest/account separation, environment/origin differences, retained async resolver identity, paths, root aliasing/traversal, existing and dangling symlinks, changed ancestors, file/directory mismatches, missing legacy source and explicit legacy non-ownership.

## Exact API

| Symbol | Contract |
| --- | --- |
| `DeviceDataEnvironment(kind:apiOrigin:)` | Immutable, validated `.production`, `.staging` or explicit `.development` plus canonical origin. Host case/default HTTPS port/root slash normalise; credentials, query, fragments, API paths, malformed ports and non-HTTPS external origins fail. Plain HTTP is accepted only for explicit development loopback. |
| `DeviceDataScope(environment:principal:)` | Immutable ownership namespace. Principals are `.account(backendUserID: UUID)`, `.guest(installationGuestID: UUID)` and `.unclaimedLegacy(sourceFingerprint: String)`. No email/provider-subject inference or login-triggered conversion exists. Guest UUID must be persisted by the future coordinator, not regenerated per login. |
| `scope.backendUserID` | Non-nil only for the explicitly supplied account UUID. Legacy and guest scopes return nil. This is an ownership descriptor, not verification of a session or server permissions. |
| `scope.storageKey` | Stable environment + canonical-origin SHA-256 + tagged principal. Same backend UUID on another origin/environment receives a separate namespace; account and guest UUIDs cannot collide. Legacy fingerprints require 64 hexadecimal characters and normalise case. |
| `DeviceDataStorageRoots(applicationSupport:caches:temporary:)` | Explicit canonical filesystem roots; no `.default` global root lookup, mutable singleton or filesystem creation. Rejects remote/non-file URLs, traversal, query/fragment, unexpected file types, symlinks and overlapping durable/evictable roots. |
| `DeviceDataScopePaths(scope:roots:)` | Immutable account/guest plan. Rejects every unclaimed legacy scope. Does not open or switch SwiftData, create directories, claim data, upload, delete, or instantiate UserDefaults. Every lookup rechecks existing ancestors. |
| `storeURL`, `documentsDirectory`, `photosDirectory`, `floorPlansDirectory`, `recoveryDirectory` | Throwing getters for scoped locations; fail without falling back to installation-wide storage. |
| `directory(_:)`, `file(_:in:)` | Named areas `.database`, `.documents`, `.photos`, `.floorPlans`, `.preferences`, `.recovery`, `.sync`, `.quarantine`, `.cache`, `.temporaryExports`. File resolution validates each relative component and expected existing file type. |
| `photoURL(for:)`, `floorPlanURL(for:)` | Preserve current model-relative conventions while selecting the correct scoped media root. Neither method looks up whichever account is currently active. |
| `preferencesSuiteName` | Stable OS-managed UserDefaults suite name for a later scoped preferences adapter. `preferencesSnapshotURL` is the recovery snapshot location, **not a second live settings database**. Neither is activated here. |
| `UnclaimedDeviceDataSource(scope:existingStoreURL:existingDocumentsDirectory:)` | Separate descriptor of actual existing, unclaimed legacy files. Requires legacy principal and existing regular store/directory. Preserves supplied locations verbatim. `preservedDocumentURL(for:)` supports read-only recovery/inventory callers; no mutation/claim API is supplied. |

## Storage layout and preservation

Within a trusted Application Support root:

```text
DeviceScopes/v1/<environment-origin-key>/<account-or-guest-principal>/
  Store/device.store
  Documents/Photos/<existing project-relative photo path>
  Documents/FloorPlans/<existing project-relative drawing path>
  Preferences/preferences.plist        # recovery snapshot only
  Recovery/
  Sync/
  Quarantine/
```

The separate Caches root uses the same scope suffix. Temporary exports use the separate temporary root and an `Exports/` suffix. Original and unsynced photos/plans therefore have a durable private destination, outside evictable caches. Original released Documents and the actual default/app-group store are not moved or renamed. Recovery output is outside the scoped `Documents` source so `DeviceRecoveryArchive.create` can retain its existing overlap checks.

The namespace layout has an explicit `v1`. A future change to origin aliases/layout must be a reviewed migration; do not quietly reinterpret an existing directory. The candidate workers.dev origin and existing recovery origin intentionally produce different scope keys. Changing AppConfiguration alone must not result in an automatic ownership claim, upload or empty replacement presented as the old account's work.

### Canonical system-root detail

The tests found that Foundation's `resolvingSymlinksInPath()` can still return `/var/...` on this Mac, while `/var` is itself a symlink. This resolver deliberately rejects such an uncanonicalised ancestor. At bootstrap, use POSIX `realpath` **only for trusted existing system directory roots returned by FileManager**, before constructing `DeviceDataStorageRoots`. The test fixture demonstrates this with the system temporary root. Do not call realpath on arbitrary imported paths, model-relative paths or a legacy store filename; that would follow a link before validation. Derive an existing legacy store path relative to its known canonical system container root, preserve the remaining path components, and let the descriptor reject any link below that root.

Every resolver call uses `lstat`, which also detects a broken symlink; `fileExists` alone would miss that trap. This is a path preflight, **not a filesystem transaction or proof against a link replaced after the URL is returned**. Future scoped I/O still needs a captured scope/lease and appropriate atomic/no-follow operations. No context/task coordinator is implemented in this file.

## Proposed integration into actual code

1. **Composition/configuration:** in `Snaglist/App/SnaglistApp.swift`, a future scope coordinator creates `DeviceDataEnvironment` from the explicit `AppConfiguration.isStaging` choice and validated `AppConfiguration.API.baseURL` (`Utilities/Configuration.swift`). Pass canonical system roots and the verified backend UUID into `DeviceDataScope`, then create a path plan. Keep the current startup store untouched until the complete transition/legacy route is ready; do not replace just the current staging URL branch with `storeURL` now. The verified recovery fingerprint and actual `ModelConfiguration.url` describe legacy input separately.
2. **Authentication publication:** `AuthManager.createOrUpdateUser(id:email:firstName:lastName:authProvider:)` already receives a UUID and immediately publishes `currentUser`/authentication. The future transition must prepare/validate the account resources using that verified backend UUID before starting new-account observers against an old container. Scope preparation failure keeps the old files and a recoverable state. `signOut` must select a persisted guest identity only after old work is drained. No auto-claim based on `currentUser`, a profile row or the next login.
3. **SwiftData lifetime:** after explicit transition approval and safe directory creation, pass `try paths.storeURL` to `ModelConfiguration(schema: DeviceModelSchema.current, url: …, cloudKitDatabase: .none)`. Recreate the root view tree under a distinct scope epoch; detach old contexts/tasks. Opening the path is a later operation and can still fail. This foundation does not choose migrations or turn a failed open into an empty store.
4. **Photo service/models:** make `PhotoStorageService` capture one `DeviceDataScopePaths` (or an equivalent explicit resolver) in its instance. `getPhotoURL`, save/load/delete/size helpers must use that captured plan; capture output paths before thumbnail awaits. `SLSnagPhoto.originalURL/thumbnailURL/annotatedURL`, `SLProject.coverImagePath` and `SLUserProfile` asset getters currently call the global singleton. Their owning context/view/exporter must supply the same captured resolver; never consult a mutable active-root global.
5. **Drawings:** `FloorPlanStorageService` should capture the same scope and use `floorPlanURL(for:)`/`.floorPlans`. `SLDrawing.fileURL` and `thumbnailURL` currently route through PhotoStorageService, which is a real existing discrepancy; use the explicit floor-plan resolver during that integration. Preserve stored project UUID/path casing and annotation/evidence relationships.
6. **Recovery/preferences:** pass `try paths.documentsDirectory` and the scope-owned defaults instance to `DeviceRecoveryCapture.source`; use the scope's `recoveryDirectory` as the archive parent. `DeviceRecoveryCopyView` must additionally retain a device-scope lease across awaits, alongside current `APIClient.sessionGeneration`. `.defaultAppStorage` can use a suite created from `preferencesSuiteName`, but imperative readers and singleton settings also need the same provider. Preserve the existing recovery preference allowlist; Keychain/session/token queues do not become ordinary settings.
7. **Queues/cache/export cleanup:** `.sync`, `.quarantine`, `.cache` and `.temporaryExports` provide destinations only. Queue ownership/immutable retries, per-operation receipts, cursors and cancellation remain separate implementations. Bind `SyncManager`, `MagicLinkSyncService`, Comment/Approval services, exporters and widgets to the coordinator's lease; the current globals are not made safe merely by adding these types. Cache cleanup must be scoped to the cache area and never delete original media or recovery copies.

## Remaining gates

Root must register the source in PBX and include the test file in the actual native test target, then build/run the focused app tests. A full scope coordinator, safe directory creation/I/O, durable guest identity and explicit legacy claim ledger, service binding/unbinding, view/widget/cache disposal, per-account preferences, file protection/backup policy and interrupted transition/import tests remain. Complete native reconstruction/outbox/pull and iOS → portal → contractor → acceptance parity remain separate R1/R4 gates. No current production record, store, file or preference has been changed by this foundation.

References: `outputs/readiness/IOS-SCOPE-IMPLEMENTATION-NOTES.md`; native `docs/platform/DATA-MIGRATION.md`; `Snaglist/Services/DeviceRecoveryArchive.swift` and `DeviceRecoveryCapture.swift`. Those existing artifacts explain the recovery boundary and original-schema preservation; this slice does not supersede them with a migration claim.
