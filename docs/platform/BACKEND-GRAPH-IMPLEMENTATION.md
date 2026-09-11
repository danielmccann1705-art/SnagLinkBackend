# Backend project graph groundwork — 11 September 2026

## Assessment

The backend now has an additive, actor-bound project discovery inventory and normalised internal snag comments. These close two concrete gaps in account reconstruction. **They do not complete native project synchronisation, import or go-live readiness.** The final focused PostgreSQL verification passed **31 tests, zero failures and zero skips**, including all 16 new graph cases plus existing workflow/media checks. The earlier 37 canonical mutation cases also passed on unchanged product source. No deployment, customer data import or provider action is part of this slice.

Repository: `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`, branch `feature/unified-platform`, starting HEAD `a23fe3e4075902fec1d90055975c9f22d88dfada`. Final source-only checkpoint: **`91a53d97e47346bfe4c96da2378e0aac12927046`**, containing exactly the 12 graph source/test/contract paths below. The verified source manifest is recorded below. Existing backend infrastructure edits by the parallel staging agent are outside this slice.

Controlling scope: implementation brief v1.1, sections 9, 10, WP-03 and G1; local readable copy `work/portal/source-brief.md`. Root is independently implementing recoverable native backups and account-scoped data activation. This backend work must not be described as that native implementation.

## Actual graph coverage

| Graph edge | Current server truth and native gap |
| --- | --- |
| Project discovery | Added immutable, current-authority-checked actor inventory. Existing `PlatformProjectController.list` uses offsets sorted by mutable `updatedAt`; retain it for browsing, not destructive local reconciliation. |
| Project metadata | `Project` / `ProjectResponse` store core identity/contact/location/status fields. Native `SLProject` also has custom project type, start/end dates, folder/tags and relationship information without complete canonical counterparts. Never discard these on import. |
| Snags and assignments | Canonical `Snag`, `PlatformSnagResponse`, revision/workflow revision, stable UUID, allocated display number and current contractor/trade references exist. General patches cannot set approval state or drawing relationships. Native references need a stable alias/import policy. Normalised `assignment_history` exists and is written by `PlatformSnagService.assign`, but its historical rows are not included in register snapshots; only current assignment and subsequent snag deltas are covered. |
| Contractors and trades | Normalised workspace directories and revisioned mutation receipts exist; register snapshots include their managed records. Workspace authority replaces creator-only access for these v2 paths. |
| Photos and annotations | Private `media_assets` handles snag-bound JPEG/PNG `capture` and `completion` uploads, processed rendition metadata and attached manifests. Native original/thumbnail/annotated file relationships, custom labels, capture date/GPS/sort order and annotation version linkage are not completely represented. |
| Drawings, versions and pins | No canonical drawing/version/page graph exists. `SyncedDrawing` is legacy link-token file metadata. Native `SLDrawing` has UUID/name/local file/thumbnail/page/sort order; `SLSnag` has drawing UUID and X/Y. These are not sufficient to reconstruct immutable page geometry safely across native/web. |
| Internal comments | Added `project_comments` with stable IDs, authenticated author attribution, root/reply relationship, creation time, revision and redaction tombstone. Included in current register snapshot/deltas. Not a historical `SLComment` import: legacy author/time, mentions, attachments and Contractor-link comments remain outside this slice. |
| Completion / review | Existing normalised completion attempts, review decisions and their attached media remain canonical. New comments do not update these tables, snag status, snag revision or workflow revision. |
| Legacy local status history | Native `SLStatusChange` carries user/contractor names and old transitions. Canonical review decisions do not prove that historical local transitions were authorised. Preserve as provenance-qualified history; do not synthesise accepted server decisions. |
| Units / floors / rooms | Current native model files have no separate Unit/Floor/Room model; plot labels can be project names and location remains snag text. The brief allows an optional unit/plot and freeform location, so future structural parity must remain optional rather than imposing an estate/building hierarchy. |
| Project organisation | `SLProjectFolder` hierarchy, `SLProjectTag` identity/colour and project relationships remain local. No opaque report JSON is substituted for these missing normalised models. |
| Local account/support state | Native profile settings, branding/signature files, notification cache, legacy links, pending operations and deletion receipts are not interchangeable with canonical project graph records. Root's account/store work owns their isolation and recovery. |

## New contract

### Authorised project discovery

`POST /api/v2/project-discovery-snapshots` creates an immutable inventory; `GET` on the same route accepts `snapshot` and zero-based `offset` (multiples of 50).

`ProjectDiscoveryPage` contains `snapshotToken`, `items`, `total`, optional `nextOffset`, `complete`, `capturedAt`, `expiresAt`. Each item contains:

- `project`: the existing `PlatformProjectResponse`, including workspace/revision/capabilities.
- `bootstrapState`: `register_available`, `import_required` or `archived`.
- `coverage`: explicit register coverage only for an active, platform-managed project; empty otherwise.

`complete` means the **inventory page sequence** finished. It does not mean the complete native graph can be reconstructed. The inventory has no project-content delta cursor. Native must start the project's register bootstrap independently, even for a newly granted project whose records are older than another cursor. On foreground and periodic reconciliation, re-read the retained inventory token to revalidate access; create a replacement when changed or expired. Account/workspace transitions also require revalidation. Avoid opening a redundant new inventory on every foreground. Push-only discovery is not implemented.

Limits: 100 current workspaces, 2,000 accessible projects, 50 items per page, five active inventories per actor, 30-minute expiry. Above the workspace/project bound the server returns `discovery_job_required` and no partial inventory. A larger background job is absent. Creating a replacement discards only that actor’s expired or access-invalid inventory caches, so repeated membership changes cannot exhaust all five slots; other valid snapshots remain reusable.

Stored tokens are hashed and actor-bound. Every page checks active user authority, current and previously captured workspace scopes, membership revisions, project grants and revisions, workspace owner/lifecycle, project access set and import/archive state. Changes require `409 discovery_restart_required`; expiry returns `410` with that identifier. No old project content accompanies a failed check. Removed/rejoined same-role membership cannot reuse an old inventory. Unsent work must remain private and recoverable.

Project metadata updates do not reorder or mutate an open inventory. Newly created/granted projects invalidate it rather than silently disappear between pages. Workspace locks are taken in UUID order and held only for each bounded database transaction. All pages must succeed before the client reconciles an old inventory; absence from an individual page or failed inventory is not deletion. A further review found that the actual v1 project create route can still leave known owner-bound records with no workspace. The combined verification patch makes both inventory creation and old-page reads fail closed with `409 project_ownership_reconciliation_required` until explicit reconciliation; it does not mutate or claim ownership. This inventory describes authorised backend projects only. A local-only or ownership-ambiguous project missing from it must remain preserved for explicit import/reconciliation, never be discarded as if it were a server tombstone.

### Normalised internal comments

- `GET /api/v2/projects/{projectId}/snags/{snagId}/comments`: current project read permission, keyset order `(createdAt,id)`, 100 items/page, optional same-snag `after` UUID and optional `nextAfter` response. This browsing endpoint is not an immutable bootstrap.
- `POST` on the same path: `ProjectCommentCreateCommand` with existing `{operationId,deviceId}` mutation metadata, stable comment `id`, `body`, optional `parentCommentId`. Current edit permission; archived snag rejects new comments. The central policy/persisted role supports read-only Viewer, but current public project grant creation allows Manager/Member only; the read-only negative test uses an explicit stored-role fixture and is not proof of Viewer provisioning UI. Parent must be an existing unredacted top-level comment on the same snag, giving one reply level compatible with the present native thread renderer.
- `POST .../comments/{commentId}/redact`: `ProjectCommentRedactCommand` with mutation metadata, positive matching `expectedRevision` and nonempty reason. Author with current edit rights, or current project manager/archive authority. Revision conflicts leave the record intact.

`ProjectCommentResponse`: `id`, `projectId`, `snagId`, optional `parentCommentId`, `authorUserId`, `authorName`, `visibility = internal`, optional `body`, `revision`, `createdAt`, optional `redactedAt`. Author/name/time come from server session and account; client-supplied author/visibility claims confer no authority. Body is trimmed, nonempty, at most 10,000 characters. Redaction reason is at most 500.

The database enforces project/workspace and snag/project pairs plus same-snag parent linkage. Future explicit personal-to-company transfer must include comment scope alongside every other canonical child; simply changing `projects.workspace_id` is deliberately not a supported transfer. App policy additionally prevents deeper/reply-to-removed threads. Original body and redaction actor/reason remain in private audit storage; public replies retain ID/thread/attribution with no text. This is not a hard deletion of accepted evidence.

Creation retries use actor-scoped immutable operation receipts and current authority checks; changing the payload under the same operation ID conflicts. A replay after redaction returns the current tombstone, never the original text. A removed user cannot retrieve a receipt.

`RegisterSyncService.coverage` now includes `comments`; items use `type = comment` and `ProjectCommentResponse`. Comments are materialised in the same bounded transaction and high-watermark as the existing register graph. Creation emits a normal project change transaction. Existing stored manifests keep their original coverage. A later redaction explicitly invalidates older register snapshots/cursors with `rebootstrap_required`, preventing old immutable payloads from reintroducing removed text. Rebuilding must preserve unsent local operations.

No Contractor-link visibility, comment notification delivery, attachment/mention API, legacy author import or arbitrary editing of posted comment text is claimed.

## Rollback restriction

After comments/redactions are used, a compatible rollback must retain comment-aware snapshot/cursor redaction checks. A pre-comment backend image has a generic graph reader without those checks, so it is **not an established safe rollback target**. Keep this feature on the candidate until an explicit compatible-image rollback test and release matrix cover the new graph contract. The migration retains original comment audit text and refuses a destructive down migration.

## Source map

- `Sources/App/Controllers/ProjectDiscoveryController.swift`
- `Sources/App/Services/ProjectDiscoveryService.swift`
- `Sources/App/Controllers/ProjectCommentController.swift`
- `Sources/App/Services/ProjectCommentService.swift`
- `Sources/App/DTOs/ProjectGraphDTO.swift`
- `Sources/App/Migrations/CreateProjectDiscoveryAndComments.swift`
- `Sources/App/Services/RegisterSyncService.swift`
- `Sources/App/configure.swift`, `Sources/App/routes.swift`
- `Tests/AppTests/ProjectGraphTests.swift`, existing snapshot coverage expectation in `CanonicalMutationTests.swift`
- `docs/api/openapi.json`, additive candidate contract version 0.11.0

The migration adds three tables and indexes, leaves existing fields/rows/old migrations intact, and is transactionally idempotent. Destructive down migration is deliberately refused; use compatible image rollback. After comments/redactions are used, a compatible rollback must retain comment-aware snapshot/cursor redaction checks. Rolling back to a pre-comment image without those checks is not verified safe: the older generic snapshot/delta reader can still see stored payload types it does not understand. This needs the release compatibility matrix before production use.

## Required next drawing/media contract

Implement these as a coherent next graph slice rather than treating a legacy `SyncedDrawing` row or report snapshot as canonical:

1. Project-scoped `Drawing` stable identity; immutable `DrawingVersion` with SHA-256, verified private object, MIME/size and version number. Native file UUID and any historical aliases need explicit import mapping.
2. Page records keyed by version and page index, with media/crop boxes, rotation, rendered dimensions and a documented top-left coordinate transform. Test asymmetric corners/interior points, rotated PDFs and multiple pages against native and browser.
3. Separate project-scoped drawing upload allocation/processing, allowing bounded PDFs and images without forcing a fake `snagId`. Recheck membership and purpose on allocate/upload/finalise/read; private gateway only. Current `PrivateMediaService` rejects PDF and supports only snag capture/completion purposes.
4. Snag pin relation to exact drawing version/page, normalised X/Y and revision-checked mutation. Replacement creates a distinct version; previous pins stay on the previous file. No overwrite or implicit relocation.
5. Native original/annotation/rendition linkage, capture labels/order/checksum metadata and explicit immutable annotation version. Preserve untouched originals and avoid accepting client-supplied storage keys/foreign asset references.
6. Snapshot/delta coverage, dependency ordering and authorised Contractor-link drawing selection. Never attach every project drawing automatically or infer scope from report JSON.

Also expose the already-normalised `assignment_history` as a typed snapshot/delta entity before promising historical assignment reconstruction; emitting only the current snag assignment cannot recreate earlier changes on a fresh device.

In parallel, add organisation/date-field parity and typed legacy import with stable-ID receipts, provenance, ownership reconciliation, dry-run/commit acknowledgment and a fresh-device comparison. Do not merge uncertain on-device authorship into canonical approval history.

## Verification and limits

- **Final relevant run:** `outputs/app-store-prep/backend-tests/project-graph-verified.json` and redacted `.log`; 31 passed, 0 failed, 0 skipped in 154.54 seconds. These comprise all 16 `ProjectGraphTests`, eight `CanonicalWorkflowTests` and seven `PrivateMediaTests`.
- **Exact final Sources/Tests/Package manifest:** SHA-256 `35d4661720d3a55147225e80ae061423b0b500b29bf46ea850adeeb73d1cb5f3`.
- **Existing canonical regression run:** all 37 `CanonicalMutationTests` passed in `project-graph-final.json` on identical product Sources. The subsequent changes only corrected new-test setup, so those passing cases were not needlessly repeated. That earlier combined run recorded 51 passed / 2 failed / 0 skipped; both new-test failures were missing test portal configuration and an unsupported public Viewer-grant fixture, now corrected and passing in the final run. Do not add overlapping suite totals as though they were distinct cases.
- Source-only Swift build also succeeded before the database pass; `outputs/readiness/backend-graph-build.log`. The final test helper rebuilt the final candidate as part of verification.
- `git diff --check` and OpenAPI JSON parsing passed. Portal contract refresh also passed: the checked-in contract now byte-matches backend commit `91a53d9`, 92 TypeScript transport types were regenerated, the production build/type checks succeeded and all **74 portal tests passed, zero failures/skips**. Portal base was `84a5223354a6aa01d561e60b05f3e59392124b02`; only `contracts/openapi.json` and `src/generated/apiTypes.ts` changed. `outputs/readiness/BACKEND-GRAPH-PORTAL-CONTRACT.json` records hashes and logs. These generated types do not add runtime UI or prove native/web adoption of the new endpoints.

The tests verify immutable discovery pagination under metadata writes, newly added grants/projects, removed/rejoined authority, actor-bound tokens, known unscoped legacy records failing closed, explicit empty/import/archive states, snapshot limits/recovery, stable comment IDs and concurrent replay, server attribution, read-only and cross-snag/thread restrictions, redaction revisions/audit retention, old-receipt/snapshot/cursor suppression, deterministic keyset pagination, database foreign-key enforcement and preserved rows on additive migration rerun. New comments leave existing snag/workflow revisions unchanged. Acceptance of a contractor submission is separately exercised by the existing workflow suite; this is not an ordinary native capture-to-portal journey.

Migration verification covers the retained prior-schema database upgrade, idempotent rerun with preserved project/comment rows, and fresh creation of the three new tables in an isolated schema with the required earlier foreign-key surface. That scratch schema is rolled back. **A completely fresh historical migration chain was not rerun on a newly created Neon database.** The existing eight-database capacity limit was respected.

Database: retained synthetic `snaglist_platform_test_0911074529_fa3f`, project `dawn-queen-24474678`, TLS verified, restricted role confirmed (no superuser/create-database/create-role/replication privilege). No database was created or dropped; customer records were not used. A restarted interactive harness may also have applied the additive migration to its separate pinned synthetic review database; verify that schema before labelling it an untouched baseline.

An initial attempt failed before connecting under the agent network sandbox; a later resumed permission tool was interrupted. Root then executed the existing restricted helper with active permissions. These environment/tool events were not Neon outages. The first compiler pass also found a test helper name collision, fixed before the executed suite; no failed result is hidden as a successful run.

**Still open:** complete native account-scoped pull/push/import and fresh-device reconstruction; missing graph edges above; real matching Linux/private-R2 staging; consumer UI adoption; throughput at declared snapshot caps; a compatible rollback drill; and the continuous iOS → second manager → Contractor link → approval → fresh-device/report acceptance journey. Passing these tests does not close G1/D1/D2 or establish production readiness.
