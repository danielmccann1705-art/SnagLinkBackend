# Canonical workflow candidate — 10 September 2026

**Implemented and compiled; database and browser integration unverified.** Backend `7b4c8cd` follows the locally verified private-media checkpoint `6d742bf`. Portal `f763ae2` follows private-photo checkpoint `1e8e387`. Both are local branches; nothing in this chapter establishes deployment or release.

## Product behaviour implemented

Five states remain authoritative: Open, In progress, Awaiting review, Changes requested and Closed. Draft publication and archive are separate attributes. Starting work does not submit evidence. Submitting completion produces a pending attempt and Awaiting review, never accepted closure. A reviewer may accept the pending attempt or send it back with a reason. Reopening requires a reason and preserves the previous acceptance. A manager-recorded internal fix has explicit internal attribution and acceptance; it does not impersonate a contractor.

Submission requires processed after photos owned by the authenticated actor and bound to the same snag/project/completion-intention UUID. Original capture photos cannot be passed off as after evidence. Only a reviewer may record a reasoned evidence waiver, and only when the after-photo list is empty. Every attempt retains its own notes, evidence links and outcome. Rejected evidence is kept for later comparison.

## Backend structure and invariants

Repository: `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`, branch `feature/unified-platform`.

- `Sources/App/Services/CanonicalWorkflowService.swift`: `execute`, `createAttempt`, `decision`, `pending`, `attempts`. Actor and capabilities are server-derived. Current project permission, snag/workflow revision and pending-attempt revision are checked under the workspace transaction lock.
- `Sources/App/Controllers/CanonicalWorkflowController.swift`: authenticated history and six explicit transitions. Operation receipts replay the original acknowledged outcome only after rechecking current scope.
- `Sources/App/DTOs/CanonicalWorkflowDTO.swift`: commands, attempt/decision/history response data and structured workflow conflict.
- `Sources/App/Migrations/CreateCanonicalWorkflow.swift`: `completion_attempts`, `completion_evidence`, `review_decisions`, `workflow_outbox`. Composite foreign keys enforce project/snag/evidence consistency; unique constraints allow one pending attempt and one outcome/waiver per attempt.
- `Sources/App/Services/RegisterSyncService.swift`: new immutable snapshots include completion attempts, decisions and attached evidence; existing manifests retain their original declared coverage. A new device can download this represented history without losing writes during pagination. This is still not the complete native graph.
- `Sources/App/Migrations/AddChangeTransactionGroups.swift` and `PlatformMutationService.change`: one opaque UUID per database transaction, using a transaction-local PostgreSQL setting. Counter, payload and group commit together. New groups are bounded to 1,000 change rows; oversized work rolls back. Delta pages target 100 changes and include the rest of their last group (at most 1,100 response rows). Clients must apply each complete group in one local transaction before advancing the cursor. Pre-migration rows and a compatible older writer receive per-row defaults; a fresh canonical snapshot is required for complete historical reconciliation.

Snag state/revisions, evidence attachment, completion attempt, reviewer decision, activity, change rows and notification outbox commit in one transaction. Queued notification is not delivered email. No outbox worker exists yet.

`GET /api/v2/projects/{projectId}/snags/{snagId}/workflow` returns newest-first pages (25 attempts, 50 decisions), current pending attempt and its evidence waiver separately. `POST` actions are `start`, `submit`, `accept`, `send-back`, `reopen`, `internal-fix`. Reads require current project access; review/reopen/internal-fix require review capability. Start/submit require contribution capability. Cookie mutations require the existing Origin/CSRF checks; native Bearer remains supported.

The maintained OpenAPI 3.1 contract is `0.7.0-candidate`, 42 paths, 54 operations and 60 generated schemas. It describes the implemented subset and explicitly marks database verification pending. Legacy v1 routes are outside that document.

## Portal integration and design

Repository: `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal`, branch `feature/unified-portal`.

`src/components/ConnectedReview.tsx` reuses the inspected D1 review heading, original/submitted image pair, full-image viewer, context columns, decision panel and history treatments. `ProjectRegister.tsx` opens it without discarding register filters, selection, detail or draft controllers. The route uses the existing project URL with snag/review query state. All customer-facing future sharing remains “Contractor link”.

`src/data/reviewController.ts` holds per-snag review notes, chosen historical attempt and immutable commands in account-owned memory. A timeout never turns a pending submission green or creates a new decision UUID. Retry confirms the same intention. A conflict reloads current history and requires explicit evidence review before preparing a new operation. Send-back/reopen require a reason. Access loss hides history; account disposal stops late callbacks. Sign-out/unload warns about pending work. This is not a durable offline queue.

The review workspace loads each attempt's private media by its exact asset ID. The current evidence waiver is available independently of history pagination. Managers can select earlier attempts; acceptance stays tied to the current pending submission. The UI waits for after images to load before offering acceptance, or shows the recorded waiver. Original and historical evidence remain available without generating or substituting proof.

**The new connected review screen has not yet been rendered or exercised against this backend.** Its production build and controller tests pass, but visual density, responsive layouts, historical photo navigation and real decision interactions still need browser inspection. Existing D1 design samples and the earlier private-photo browser capture remain separate evidence.

## Exact verification status

- `platform-workflow-current-build`: application plus all tests compile/link, 8.841 seconds; **zero tests executed**. Source fingerprint is recorded in the result JSON.
- Eight `CanonicalWorkflowTests` cover evidence requirements, duplicate/retried submissions, competing reviewers, rejection/resubmission/reopen, waivers/internal attribution, legacy/generic status bypass, transaction rollback, and immutable snapshots with a review at a delta-page boundary. **They have not passed against PostgreSQL.**
- `platform-workflow-compile`: database setup timed out for seven media cases after application compilation; no media logic was verified in that run.
- `platform-workflow-postgres16`: eight workflow cases failed during database setup (connection refused); this is not an eight-case workflow pass or eight proven product defects.
- Portal generated-type check, TypeScript and production build pass; **31 tests pass / zero failures or skips**. Six new controller checks cover uncertainty, explicit conflict review, reasons, disposal/access removal, stale reads and history pagination. The earlier four design-model workflow tests remain simulated-design tests.
- Earlier private-media checkpoint: full suite 218 pass, then seven relevant cases after the register-preview addition; actual browser upload, thumbnail, enlargement and reload verified. These results do not cover the later canonical workflow changes.

## Runtime limitation and resumption

OrbStack still reports a running runtime but its Docker API and task PostgreSQL server do not answer usable requests. The app presents a welcome/setup window requiring acceptance of its terms/privacy; Dan has been asked to complete it. No global Docker/OrbStack reset or unrelated-container change was performed.

A separate task-local PostgreSQL **16.15** was downloaded from the official PostgreSQL distribution, SHA-256 checked, compiled and installed under `work/unified-platform/postgres-local/runtime`. It could not initialise because this execution sandbox denies the required shared-memory operation (`shmget: Operation not permitted`). It is not running, created no usable database and is not a staging replacement. Source/build manifest and logs are retained in that workspace directory. [Official source installation instructions](https://www.postgresql.org/docs/16/install-make.html).

Resume by restoring the existing isolated Docker database on 127.0.0.1:55439, then run the eight workflow tests, the media/mutation regression groups and the full suite. The test helper refreshes its warm source copy automatically and records a source hash. Never point it at a remote/customer database or relax its local database-name guard. A separately provisioned isolated staging test environment needs its own verified configuration and runner.

## Not yet implemented or accepted

Canonical no-account contractor grant adapters; prepare/activate sharing; current-data contractor rendering and PIN/media enforcement; general legacy alias/evidence reconciliation; old-client compatibility adapter completion; outbox delivery/jobs; immutable reports; native account partitioning, capture/outbox/pull/import; full native graph fields/drawings; and real G1/D2 journeys. All earlier scoped blockers remain. WP-04/05/06/07 and integrated gates are not complete.
