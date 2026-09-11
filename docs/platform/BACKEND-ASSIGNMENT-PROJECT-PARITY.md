# R1: project metadata and assignment-history graph slice

Status: **implemented and tested on the current branch — 64 tests passed, zero failures/skips.** Not deployed and not adopted by native/portal consumers. This report supplements `BACKEND-GRAPH-IMPLEMENTATION.md`, which records the already-tested `91a53d9` discovery/comment slice. It does not replace that checkpoint or claim full native synchronisation.

## Scope and checkpoint

Backend: `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`, branch `feature/unified-platform`. Base HEAD for this additive work is `cd0ec67046635d6b34fe26b2389f3f5143219346`; its product Sources are the frozen `91a53d9` candidate, with the subsequent root-owned Infrastructure checkpoint. Root committed the 13 owned files as **`2c4fe4cec8ae1e584a6753956748b69586a0ac80`**, “Preserve project metadata and assignment history in canonical sync”, after the passing run. Exact product Sources/Tests/Package digest: `8f14053f4146a69ea3ad23e934b7947e3e0f64cdde1e839a4a8101e11a2d5857`. Root’s frozen `91a53d9` Linux/staging image deliberately excludes this slice.

The active brief is `work/portal/source-brief.md` version 1.1, sections 9–10 and WP-03/WP-06; release sequencing remains `outputs/readiness/GO-LIVE-PLAN.md`, R1/R4. Root approved this bounded implementation and the related receipt-capability correction. No portal, native, infrastructure, production or retained review-database changes are part of this slice.

## What the code proved

Native `SnagLink/Snaglist/Models/SLProject.swift` has `customProjectType`, `startDate` and `expectedEndDate`. The corresponding backend `Project` lacked them. Native `Views/Projects/ProjectFormView.swift` uses date-only DatePickers but persists `Date` instants; an old instant does not establish the original device timezone or intended calendar date. Preserve that ambiguity rather than silently assigning a day.

Backend `CreateAssignmentHistory.swift` already records immutable assignment IDs, project/snag IDs, previous/next contractor/trade IDs, actor ID, timestamp and the snag revision at that assignment. `PlatformSnagService.assign` previously emitted only the current snag change. A fresh device could not reconstruct this history from the change stream or register snapshot. This implementation exposes the actual normalised records; it does not manufacture history from report JSON, current assignments or present-day contractor names.

A shared project delta also contained the original writer's capability list. Server mutations already rechecked authority, but a Member could receive an Owner's UI capability hints. Delivery now projects current reader capabilities. Create/edit operation receipts likewise preserve their original result content/revision while projecting current capabilities and rechecking access before returning data.

## Additive contract

### Project metadata

`Project` adds nullable `custom_project_type`, `start_date`, `expected_end_date`, `start_on`, `expected_end_on`. Existing rows remain intact; no migration backfill guesses dates from device timestamps or report snapshots. Database checks validate actual calendar dates and enforce `start_on <= expected_end_on` when both are explicitly known.

`ProjectResponse` adds optional `customProjectType`, `startDate`, `expectedEndDate`. `PlatformProjectResponse` adds optional `canonical: {startOn?, expectedEndOn?}`. Fresh responses always carry the canonical object; optional decoding preserves older saved receipts, manifests and events. Absence of that object on an older response does not establish an empty project date.

Existing `POST /api/v2/projects` additionally accepts these fields inside its `project` input. The earlier v1 write routes retain their earlier contract; this does not make them canonical metadata editors.

New `PATCH /api/v2/projects/{projectId}` accepts:

```json
{
  "mutation": {"operationId": "stable UUID", "deviceId": "stable UUID"},
  "expectedRevision": 1,
  "fields": {"customProjectType": "Listed cottage refurbishment", "startOn": "2026-10-25"}
}
```

Allowed fields: `name`, `reference`, `clientName`, `clientEmail`, `clientPhone`, `address`, `notes`, `projectType`, `customProjectType`, `latitude`, `longitude`, `startDate`, `expectedEndDate`, `startOn`, `expectedEndOn`. Ownership/workspace/team IDs, permissions, status/archive lifecycle, cover media and favourite state are excluded from this new patch route. Their existing representations are not removed.

Authority is current personal owner or company Owner/Admin/project Manager, using central `.assign` capability; a project Member’s snag edit rights do not grant project metadata authority. Browser cookies retain existing Origin/CSRF requirements; native Bearer retains its existing path. The route takes the common actor-operation and workspace/project locks, verifies an active managed project, checks its revision, writes metadata and revision, emits a typed `project` change and stores the receipt in one database transaction. Stale updates return `409 revision_conflict` with the permitted current project and changed fields. No last-writer-wins or silent merge is introduced.

Omitted fields stay unchanged; explicit null clears. Date handling is deliberate:

- A raw `startDate` or `expectedEndDate` preserves the supplied instant and leaves its canonical date unresolved. Updating that raw representation clears the corresponding prior canonical value, because the new calendar intent is not established.
- An explicit `startOn` or `expectedEndOn` is a calendar date. The server also derives a legacy midnight timestamp using the known workspace timezone. New consumers use the canonical value for calendar presentation.
- Null in either representation clears both. Two representations of the same date in one command are rejected. Date pair changes appear together in changed-field evidence.
- An old native record requires an explicit, provenance-aware date resolution during import; this slice does not choose its source timezone or perform that import.

Create and edit retries remain idempotent. Reusing an operation ID with different work conflicts. Current workspace/project access and active state are checked before replay. Replays keep immutable historical content/revision and the original stored receipt; only the response capability projection changes. A successful old create receipt cannot recover an archived or no-longer-permitted project.

### Assignment history

`AssignmentHistoryResponse` contains `id`, `projectId`, `snagId`, optional `fromContractorId`, `toContractorId`, `fromTradeId`, `toTradeId`, plus `snagRevision`, `actorUserId`, `createdAt`.

- Snapshot entity type and coverage entry: `assignmentHistory`.
- Deterministic snapshot order: `snag_id`, stored `snag_revision`, `id`.
- Old history rows are included whether or not the old change stream contains a matching event. Their stored revision is preserved, never replaced with the current snag revision.
- New assignment changes emit an immutable `assignmentHistory` entity at entity revision 1, with its own stable database ID and the actual snag revision at that transaction. The matching updated `snag` event shares the same transaction group. An idempotent retry adds neither a second history row nor a second change.
- The existing bounded delta reader includes the entire final transaction group, even at the nominal 100-row page boundary. Clients must apply each complete group atomically before advancing the cursor.
- Historical contractor/trade IDs are attribution; they may no longer correspond to active/current directory entries. There is no guessed name, actor identity, reassignment command or history-edit route.

### Coverage, permissions and pagination

Fresh register snapshots now advertise `assignmentHistory` and `projectMetadataV2` in addition to the prior coverage. Metadata is part of the existing project item, not an extra entity. The 10,000-item cap now counts history rows; larger projects still explicitly require a background snapshot. No partial download is reported as complete.

`project_change_cursors` gains a `coverage` array. New cursors inherit the **originating immutable manifest’s** coverage and retain it through delta rotation. Old cursors default to an empty array, meaning unknown coverage. `ProjectChangePage` returns that coverage; older server responses may omit it. Neither an existing manifest nor a cursor is relabelled as supporting new history after a server upgrade. A client requiring these entities must start a new snapshot when its coverage is missing, retaining unsent work. Receiving new history events alone cannot fill omitted older history.

The existing actor-bound token, current ACL/fingerprint, membership/grant revision, archive, expiry and redaction checks remain in every page/cursor path. Revocation responses return no project/history content. Project event payload capabilities are replaced with the current reader’s capabilities without rewriting stored project data or the shared event. Private immutable snapshots already have actor-specific capabilities and remain subject to fingerprint invalidation.

## Source files

- `Sources/App/Models/Project.swift`
- `Sources/App/DTOs/ProjectDTO.swift`
- `Sources/App/DTOs/ProjectGraphDTO.swift`
- `Sources/App/Controllers/PlatformProjectController.swift`
- `Sources/App/Services/PlatformProjectMetadataService.swift`
- `Sources/App/Services/PlatformSnagService.swift`
- `Sources/App/Services/RegisterSyncService.swift`
- `Sources/App/Migrations/CreateProjectMetadataParity.swift`
- `Sources/App/Middleware/PrivateRequestLoggingMiddleware.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/ProjectMetadataGraphTests.swift`
- `Tests/AppTests/CanonicalMutationTests.swift` (coverage assertion only)
- `docs/api/openapi.json`, candidate version `0.12.0`

Patches prepared under `work/backend-project-parity/` were applied by root because this agent’s write sandbox did not inherit the root’s backend permission. No further user permission was requested. Existing `.agent`, `.agents`, `.claude`, `.cursor` and `.env (1).staging.example` entries were preserved.

## Verification status

**Final run:** `outputs/app-store-prep/backend-tests/project-metadata-graph-initial.json` and its redacted `.log`; **64 passed, 0 failed, 0 skipped**, including all 11 `ProjectMetadataGraphTests`, 16 `ProjectGraphTests` and 37 `CanonicalMutationTests`, in 267.819 seconds. Source compilation and database upgrade succeeded; no compile/runtime failure lines. The existing helper used `ProjectMetadataGraphTests|ProjectGraphTests|CanonicalMutationTests`. The current source digest matches that tested run; `git diff --check` also passed. No additional source change followed the passing run. The test database is the existing synthetic `snaglist_platform_test_0911074529_fa3f` in Neon project `dawn-queen-24474678`, with TLS/restricted-role checks. No database is created/dropped, no customer records are used, and the separate retained UI/staging review database is not migrated.

The 11 passing new tests cover explicit calendar/raw timestamp round trips, immutable metadata snapshots and subsequent deltas, concurrent receipt replay, explicit clears and preserved fields, stale drafts, invalid dates/coordinates/protected fields, current manager/member/removed/archive permissions, receipt capability changes after actual company ownership transfer, reader-specific delta capability projection, historical assignment IDs/revisions, assignment transaction pagination, old coverage continuity and revoked access. Migration tests exercise a fresh minimal prior-schema surface, idempotent rerun and preserved prior/new rows in a rolled-back synthetic schema; they do not claim a complete newly provisioned historical database build.

OpenAPI JSON parsing and all 959 local schema references passed; 97 schemas are present. `git apply --check` passed before application. The existing bounded portal generator also passed in a separate scratch directory, producing and checking all 97 transport types without altering the live portal package. Generated portal types and native consumers have not adopted this new contract; the frozen portal/staging candidate remains on its earlier schema.

## Compatibility, rollback and remaining R1

This is an additive working-branch graph slice. It is not deployed or included in root’s frozen `91a53d9` image; do not mix the new migration/schema contract into that staging acceptance evidence. The new migration retains columns/history and refuses destructive down migration. A compatible old image may ignore extra fields, but it cannot be used to claim continued metadata/history sync: old assignment commands do not emit typed history events and old cursors do not expose coverage. A feature-aware rollback compatibility drill is still required.

Old create routes silently ignore unknown additive input. A new native import must not treat an older server’s HTTP 200 as acknowledgment of these fields: inspect the returned canonical metadata and require expected coverage before claiming parity, retaining immutable operations and originals if unsupported. The existing health version is not an implemented metadata capability handshake. This consumer gate remains necessary before rollout.

**The earlier comment redaction restriction still applies:** once comments/redactions are used, rollback must retain comment-aware snapshot/cursor checks. A pre-comment reader can expose stale stored payloads. Do not treat an older build’s successful start as proof of safe rollback.

Still missing: native adoption of discovery/graph metadata/history, complete immutable capture outbox and account-scoped merge/import; project folders/tags and relationships; drawings/immutable versions/pages/pins; photo originals/annotations/renditions/order/custom labels and private drawing media; legacy display-reference mapping; explicit project transfer; safe import of ambiguous local history/ownership; project cover asset parity; background snapshots beyond caps; continuous second-device reconstruction and ordinary iOS → second manager → Contractor link → approval → report acceptance. No raw report JSON becomes master data. Viewer policy exists but public Viewer provisioning remains unimplemented as recorded in the earlier report.

The useful next step is to adopt this contract in account-scoped native import/pull with explicit coverage requirements, while implementing the missing drawing/media/organisation slices. Only a successful fresh-device comparison and real end-to-end staging journey can close R1/R4.
