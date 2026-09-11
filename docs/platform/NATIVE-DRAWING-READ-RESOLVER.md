# Native drawing read resolver — integrated and tested

## Current integration checkpoint — 11 September, 20:19 UK

Implemented on native branch `feature/unified-platform`, commit `339203a2b2a8069918496205f6cef745cc719397`. The real Xcode **Snaglist Staging** build and suite passed: **331 passed, zero failed, five existing skips** (336 total), including the 35 drawing resolver cases. The app reopened its existing synthetic project; capture `native-project-339203a.jpg`. No release or remote drawing upload is implied.

Root applied the prepared read resolver to the real app target, added PBX membership, declared the SwiftData model's computed URL getters `@MainActor`, and made the asynchronous report fallback await `FloorPlanStorageService.loadFullResolutionImage`. All imports, stored IDs, paths, file bytes, deletion destinations and API contracts are preserved. The first full builds caught the missing actor declaration and the report call-site; both were fixed before the passing run. [Exact test evidence](https://drive.google.com/file/d/1NEft9gPGqJtYARdzQnzjkDT1FWjt8GOl/view).

Ordinary image/multipage-PDF import, picker/viewer/report output and authenticated upload still need end-to-end verification. The passing file fixtures and app build do not close canonical drawing sync or D2. The preparation details below are historical and explain the patch's design; integration steps 1–2 are now complete.

## Original preparation record

Prepared 11 September 2026. **Implemented and tested in an isolated patch workspace; not yet applied to the iOS repository, built as the full app, released or deployed.** Root owns final integration and Xcode verification.

## Confirmed defect and effect

At native commit `ba10346edbf197a98e28b5d6535eddf204a39356`, `SLDrawing.fileURL` and `thumbnailURL` use `PhotoStorageService.shared.getPhotoURL`. That constructs a location under `Documents/Photos`. Actual `FloorPlanStorageService.importImage`, `importImageFile` and `importPDF` write selected drawing pages and thumbnails to `Documents/FloorPlans` and persist paths relative to that directory.

Consequently the model getters point at absent files for ordinary current imports. The viewer and PDF report compensate with a separate FloorPlans-first load. `MagicLinkSyncService.syncDrawingFile` and `syncDrawingFileWithTracking` use only `drawing.fileURL`, so ordinary imported drawing bytes can be skipped. The untracked helper silently returns; the tracked helper logs skipped and returns false. The floor picker also consumes `drawing.thumbnailURL`. This is a code-confirmed lookup defect; this task did not run a real upload or assert production occurrence counts.

## Existing storage paths and compatibility

| Data | Existing path and stored reference |
| --- | --- |
| Imported image page | `Documents/FloorPlans/<projectUUID>/<fileUUID>.jpg`; model stores `<projectUUID>/<fileUUID>.jpg`. |
| Imported image thumbnail | Same directory, `<fileUUID>_thumb.jpg`; model stores the relative path. |
| Imported PDF rendered page | `Documents/FloorPlans/<projectUUID>/<pdfUUID>_pageN.jpg`, corresponding `_thumb.jpg`, pageNumber N. Each selected page receives its own `SLDrawing.id`. |
| Original imported PDF | `Documents/FloorPlans/<projectUUID>/<pdfUUID>_original.pdf`. Retained loose source file; inspected `SLDrawing` schema has no source-PDF relation. |
| Legacy Photos lookup | `Documents/Photos/<exact stored relative path>`. Old photo-backed paths may include `originals/` or `thumbnails/`; only an exact stored path is supported, with no guessing or folder remapping. Historical use of every such shape is not established. |
| Review-mode old Photos lookup | `temporaryDirectory/ReskinReview/Photos/<exact relative path>`, matching existing PhotoStorageService review-root logic. FloorPlanStorageService's current Documents destination is preserved. |

No migration, file copy, rename, deletion, directory creation, ID/path rewrite, new media relation or schema change is included. Original PDFs are never inferred from a page filename. Canonical drawing graph work remains separate, as confirmed with `backend_sync_graph`; local resolution does not establish an upload right, public access or canonical asset membership.

## Implementation

The new pure `DrawingFileResolver` has injected `floorPlansRoot` and optional `legacyPhotosRoot`. It accepts literal relative paths, rejects empty/absolute paths, dot traversal, empty components, backslashes, URL syntax, percent-encoded ambiguity and control characters. It checks every root ancestor and relative component through file metadata. Directories must be directories; the leaf must be a readable regular file. Symlinks are rejected at all levels, including in-root, dangling, root and ancestor symlinks.

The current FloorPlans file wins deterministically when both roots contain the same relative name. The legacy root is inspected only when the current path is genuinely absent. Invalid paths, symlinks, non-directory parents, non-regular leaves and access errors do not select older bytes. The resolver returns the current file even if its bytes are empty or undecodable: image decoding remains the consumer's responsibility and cannot silently choose a stale legacy image instead.

Apple's `/var` system alias needs special handling. Fixture tests showed that Foundation's `resolvingSymlinksInPath` retained `/var`, so blindly rejecting all ancestors also rejected valid container paths. `canonicalContainerAnchor` now uses read-only `realpath` solely on an OS-provided Documents/temporary anchor. The app then appends FloorPlans/Photos and runs strict validation. It must never be used to canonicalise a persisted relative path or app-owned storage root, because that would bypass symlink rejection.

`FloorPlanStorageService.resolveExistingURL` is the shared read facade. The existing `resolveURL` remains unchanged as the current write/delete destination: read compatibility must not expand deletion into the legacy Photos root. Existing import and upload API contracts remain unchanged.

## Prepared files and consumers

All deliverables are under [work/native-drawing-resolver](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/native-drawing-resolver):

| File relative to native root | Prepared change |
| --- | --- |
| `Snaglist/Services/DrawingFileResolver.swift` (new) | Injected-root read validation and trusted OS-anchor canonicalisation. Explicitly nonisolated pure value type, compatible with the app's MainActor default. |
| `Snaglist/Models/SLDrawing.swift` | Both file getters use the shared validated read facade. No stored properties/relationships change. |
| `Snaglist/Services/FloorPlanStorageService.swift` | New read facade; downsampled/full-resolution read methods use it. Import/delete functions unchanged. |
| `Snaglist/Views/FloorPlans/PDFPagePickerView.swift` | Uses validated existing thumbnail URL rather than constructing an unchecked URL. |
| `Snaglist/Views/FloorPlans/FloorPlanViewerView.swift` | Corrects the obsolete fallback comment. Existing full-resolution decode fallback remains but resolves the same current-first path; decoding failure alone cannot choose Photos. |
| `SnaglistTests/DrawingFileResolverTests.swift` (new) | Temporary-file fixture tests. |

The model/service change automatically reaches:

- `MagicLinkSyncService.syncDrawingFile` and `syncDrawingFileWithTracking` (unchanged transport and status handling).
- `ReportsView` floor-plan preload (its downsampled read and model getter fallback now use the same resolver).
- `FloorPickerSheet` and `DrawingThumbnail` model getters, plus existing service-based thumbnail fallback.
- `FloorPlanViewerView` current loading path and full-resolution fallback.

`drawing-read-consumers.patch` includes all four existing-file edits and both new files. `source-manifest.json` records exact base and replacement SHA-256 values. `originals/` contains the four exact pre-edit files. At handoff all four current repository files still matched their recorded base hashes; `git apply --check` passed, and native Git status was clean. No native or PBX file was written by this task. No further portal files were edited.

## Executed verification

- Strict Swift 6 resolver module compile: passed, no diagnostics.
- Direct installed Swift Testing runner: **15 tests in one suite, 35 parameterized cases, zero failures**, final run 0.037 seconds. All files belong to individually created synthetic temporary fixtures; no real app media is read or mutated.
- iOS 26.2 Simulator SDK typecheck: **passed** the resolver and exact replacement FloorPlanStorageService in Swift 5 mode with default MainActor isolation, using small logger/review-mode stubs. No diagnostics.
- Read-only native `git apply --check`: passed.

Tests cover both current image/thumbnail paths, current-vs-legacy precedence, missing root/project/file fallback, exact legacy originals/thumbnail paths, no-root creation, disabled fallback, malformed paths, root/project/leaf/ancestor/in-root/dangling symlinks, directory type mismatches, empty/undecodable canonical files, distinct PDF pages without original-PDF inference, missing pages and unchanged bytes/modification dates after repeated reads.

Evidence:

- [Tests](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/native-drawing-resolver-tests.log)
- [Strict module compile](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/native-drawing-resolver-module.log)
- [Test compile](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/native-drawing-resolver-test-compile.log)
- [Service iOS SDK typecheck](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/native-drawing-resolver-service-sdk-typecheck.log)

A broader standalone SDK check including the exact `@Model SLDrawing` was blocked by the nested SwiftData macro host: `sandbox-exec: sandbox_apply: Operation not permitted`, followed by a malformed `swift-plugin-server` response. No sandbox was disabled and no escalation was requested. This is why the narrower successful service SDK probe is distinguished from full model/app integration. Initial direct test compiler setup needed the installed Testing framework and macro plugin paths; once configured, the actual tests ran and caught the `/var` fixture bug before the final pass.

## Root integration and remaining checks

1. Inspect the manifest/base commit, then apply the prepared patch once Xcode is idle. Add `DrawingFileResolver.swift` to the app's source membership (including its staging target as appropriate). Ensure the new test is included by the existing test-folder mechanism; this task intentionally did not edit PBX.
2. Build/test the actual native targets to verify SwiftData macro integration and all UI consumers. The standalone service check does not cover the full SwiftData-generated model or report view.
3. With synthetic app data, import an image and multi-page PDF; inspect page picker, drawing thumbnails, floor picker, viewer and report output. Confirm page IDs/pins are unchanged and missing pages show honest failure rather than a guessed original PDF.
4. Exercise a legacy Photos-backed drawing fixture and a current/legacy same-name collision. Confirm current bytes are displayed/exported and an unsafe or unreadable current candidate cannot select old bytes.
5. On isolated staging, verify the existing drawing upload now receives the intended imported page bytes. Do not interpret this path fix as completion of drawing graph/version synchronisation.

Limits: this is read-path validation at lookup time, not an atomic file-descriptor lease spanning later image/Data reads. A concurrent external filesystem replacement between lookup and consumer read is not solved here. The current app-managed roots and ordinary synchronous consumers make the bounded fix useful, but the upcoming account/environment storage partition and canonical media ownership must still provide their separate lifecycle/permission guarantees. The pre-existing unchecked deletion resolver is intentionally unchanged and should remain a separately reviewed deletion task; no new path from reads to deletion has been introduced.
