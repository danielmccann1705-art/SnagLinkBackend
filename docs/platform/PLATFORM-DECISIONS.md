# Platform implementation decisions

## Defaults from v1.1

Use the existing Vapor/PostgreSQL backend and React portal, approved supplied brand assets and existing design work. Extend Team as workspace; do not introduce a duplicate Company model. Preserve personal projects by default. Workspace Owner/Admin/Member and explicit project Manager/Member grants govern access. Contractors retain no-account Contractor links. Submission, awaiting review and accepted closure remain separate. Test commerce only until its activation gate passes.

## Identity proof

Legacy `users.email` values were mutable; they are not automatically migrated into verified identities. Apple provider subject preserves the existing user UUID. A verified email can be added to that existing account using both current authentication and one-use email proof. Email sign-in resolves `user_identities`, never an arbitrary matching profile. An unverified legacy claim or collision returns an explicit recovery conflict without consuming the challenge. Do not merge or discard conflicting accounts automatically. Historical email-only users with no valid account credential need an explicit recovery route; this remains an open lifecycle acceptance case.

Browser sessions use a Secure, HttpOnly, host-only cookie, seven-day server expiry, hashed credentials, environment/origin binding, CSRF and origin checks. Sign out everywhere increments a user authentication version, invalidating old native tokens too. Browser login is bound to the requesting browser. Landing GETs never consume tokens. Redirect destinations are fixed. API configuration requires explicit PORTAL_ORIGIN and PLATFORM_ENVIRONMENT.

## Workspace transition

Existing `Project.teamId` remains historical metadata. Migration gives projects with a verified existing owner a personal workspace regardless of that older team ID. Orphan project ownership is not fabricated. Existing teams receive their recorded real owner's membership only; old invitation statuses alone do not prove membership. New invitation tokens are stored hashed; old raw invitation tokens are hashed during the additive migration. Membership and selected project grants commit atomically after verified-recipient checking. Old accepted invitations are not silently backfilled.

Company access is still under implementation: the new project routes enforce the central policy; all legacy/media/job routes must be reconciled before shared-project rollout. Do not treat the passing pure policy or new service tests as complete route-wide enforcement.

## Design continuity

Existing register, detail, review and contractor development samples are preserved. Real sign-in uses the same supplied wordmark, Plex typography, Marker/Ink/Stone tokens, controls and restrained layout. Development fixtures stay excluded from production output. Project cards now open an API-backed register/detail and revisioned edit form. This is a partial connection of the established core, not a complete workbench: creation, media, sharing, review, bulk and the remaining screens are still open. D1 still needs a continuous recording and fresh native PDF comparison. D2 and the real iOS-to-second-manager close-out journey remain outstanding.

## Canonical writes and deletion

New v2 projects are explicitly platform-managed. Historical projects require a separately verified import; calling a read endpoint is not a migration. Both company projects and platform-managed personal projects reject legacy revisionless/snapshot writes. Existing unmanaged personal recovery paths remain available. The current canonical slice covers project creation and snag textual fields, references, publication and archive/restore; it now also covers workspace directories, assignment history and exact values. Complete project graphs, media and workflow commands remain open.

Each canonical operation uses stable actor/operation/device IDs and a sorted payload hash. Successful responses are retained transactionally; a replay first rechecks current permissions. Reusing an operation ID with different work fails. Snag edits require a base revision, preserve absent fields and clear explicit nulls. Conflicts return the current permitted snag and changed fields. Generic edits cannot change state, ownership, assignment, evidence, reference or closedAt.

Logged snags use an audited, reasoned reversible archive. Their UUID/reference, evidence and accepted state remain; restore is explicit and revision-checked. A contributor can discard only their own unpublished draft; managers can archive logged work. Reference numbers are allocated under the project workspace lock and never recycled.

Change rows use a workspace counter advanced inside the same locked transaction, not sequence allocation order. The register snapshot service now freezes project/snags plus workspace-managed contractors/trades into bounded immutable pages and pairs its high-watermark with authenticated per-project deltas. Snapshot/cursor checks revalidate membership on every request; rejoining requires a fresh bootstrap. Coverage is explicitly project/snags/contractors/trades, not complete device synchronisation. Media, drawings, completion history, local organisation and migration must join the full graph contract before WP-03 or G1 can pass.


## Directory and assignment authority

Extend existing Contractor/Trade rows with workspace, revision and managed-state metadata; do not create a parallel company directory. Legacy directory ownership is retained in the personal workspace without claiming it as a completed import. Workspace Owner/Admin may manage the directory. An assigned project Manager may manage it using that project's verified context; assigned Members may read it, not edit it. Personal directories remain private. Composite database keys reject contractor/trade references from another workspace.

Contractor-to-trade relations are normalised and updated in the same transaction as the retained legacy ID array. Assignment is a separate Manager command with revision checks and an append-only history record. Current assignment cannot change while a snag awaits review or is closed. When the new LinkGrant service is added, reassignment must revoke affected old grant access in this same authority boundary; the new grants are not implemented yet.

## Calendar dates and exact money

`canonical.dueOn` is a validated YYYY-MM-DD calendar date; it never passes through JavaScript Date for editing. `canonical.costEstimateDecimal` and `actualCostDecimal` are exact decimal strings backed by PostgreSQL NUMERIC, with currency and at most six fractional digits, bounded 0–1,000,000,000. Blank and recorded zero are different. This permits precise construction estimates without a binary-float round trip. Display/currency rounding belongs to presentation, never silent mutation.

Released timestamp/Double columns remain compatibility mirrors. Earlier unreleased v2 timestamp/number inputs are deprecated adapters: timestamps are interpreted in the workspace timezone; excess cost precision is rejected, not rounded. Supplying both representations in one command fails. New clients use the canonical fields. Stored pre-parity candidate receipts/snapshots may omit the canonical envelope; refetch before displaying/editing those fields. Existing device/legacy values are not automatically claimed or converted by this migration. Managed candidate values needing reconciliation stop the migration instead of disappearing.

## Native environment isolation

The staging scheme has distinct bundle/Clip IDs, an explicit store in its own sandbox, a separate Keychain service and no production app-group/push/RevenueCat access. The build cannot switch endpoints at runtime. `IOS-STAGING.md` records implementation and provider prerequisites. This does not complete account isolation, anonymous claiming, cache revocation or device migration inside one installation.

## Maintained API contract

Backend `docs/api/openapi.json` is the maintained implemented-v2 contract; the portal keeps an identical copy and generated types. Its current version is `0.5.0-candidate`. Generate/check types as part of the web build. Absent endpoints and incomplete snapshot coverage are explicitly documented. Do not extend web transport types independently or treat an API schema as acceptance evidence.

## Project-access removal and stale invitations

Project grants are retained with active/removed state and a revision. Removing a grant increments its version; re-adding it cannot reset to revision zero. POST project members requires mutation metadata, expectedRevision and an explicit role or null. Owner/Admin removal does not pretend to remove company-wide rights. Project Managers can add Members but cannot remove/promote/demote privileged access. Listing project members is bounded and permission checked.

Pending invitations capture the revision of each offered grant. Acceptance and preview fail when those permissions have since changed, preventing an old invitation from undoing a later removal. Fresh invitations to former Managers do not silently restore the old Manager privilege. Accepted invitation previews recheck current project access before showing names. Snapshot/delta fingerprints include grant version, so removing/re-adding the same role requires a fresh bootstrap.

## Connected register and edit intentions

Server register pages apply literal case-insensitive search, status, priority, contractor/unassigned, location and calendar due filters before returning at most 50 records. Counts and labels come from the same authorised view; absent results are never tombstones. Sort ties are stable and missing dates sort last. This is live offset pagination; a concurrent edit can move rows between pages. It does not replace immutable device snapshots or the complete graph contract.

The browser retains current authorised results during a refresh, cancels superseded reads, preserves per-project in-memory drafts and context, and clears visible cached records when access loss is observed. No project records or credentials are persisted in browser storage by this slice. A timeout keeps the exact operation ID/base/payload for deliberate retry and locks changes to that uncertain intention. A revision conflict shows current versus proposed values and requires explicit comparison before a new save. Signing out destroys the account-owned cache; expired-session recovery requires the same account. Full refresh/reload and developer hot reload can still discard in-memory drafts; ordinary navigation preservation is not durable offline storage.

## Truthful identity-email delivery and local verification

V2 sign-in/email proof now fails with 503 if its mail provider is absent; it no longer reports a successful send through the older notification helper's no-op. The existing v1 helper's behaviour is unchanged and remains an explicit legacy follow-up. A DEBUG-only, heavily scoped local mailbox supports browser inspection without sending mail. It requires development/local mode, a loopback listener/origin/DB, the exact disposable browser database and a synthetic @example.test recipient. Its files/temporary authentication links are private verification material, not source or handover artifacts. Production/staging provider round trips remain separate gates.


## Current checkpoint — private media and review, 10 September 2026

Backend `7b4c8cd` (workflow candidate; private-media base `6d742bf`); portal `f763ae2` (review candidate; private-photo base `1e8e387`); native `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`. Local branches only; no deployment/release.

**Verified locally:** private original/processed media, authenticated gateway, revisioned capture attachments, real portal photo upload/thumbnail/enlarge/reload. Backend full suite 218 pass before the last register-preview addition, then seven relevant cases pass; portal build and 31 tests now pass.

**Implemented but unverified in the database/browser:** canonical attempts, decisions, evidence consumption, reasoned waiver/internal fix/reopen, queued notifications, completion-history snapshots, transaction-grouped deltas and the connected review workspace. All backend application/test code compiles. The eight new workflow tests failed at database setup, so none is a workflow pass. The new review workspace still needs actual browser rendering/interaction inspection; the earlier connected-photo capture is separate evidence.

**Current blocker:** OrbStack/Docker's task database stopped responding and the OrbStack app shows setup requiring Dan's acceptance of its terms/privacy. A separate official PostgreSQL 16.15 source build succeeded, but the sandbox denied shared-memory initialisation. Neither path currently supplies a working test database. Existing databases/other projects were not reset. Native build still has its separate package-sandbox/CoreSimulator block.

See [WORKFLOW.md](https://drive.google.com/file/d/1x8NH7hxbBjoeyv65CUVfEuE-_iytKfZB/view) for architecture, exact file/symbol references, test labels and resumption instructions; [PRIVATE-MEDIA.md](https://drive.google.com/file/d/1h3md2ZhJ4rlrJdakMHsKEwTD0o36riEP/view) for upload/storage boundaries. D1 recording/fresh native PDF, real D2 and G1–G5 remain open. Earlier dated sections are historical checkpoints, not claims that later code passed their tests.

### Added decisions

- Keep originals and processed renditions in a separate private bucket; no fallback to the old public upload bucket. Private access is checked again after storage fetch. Processed completion evidence is bound to an immutable intention and only becomes shared in its submission transaction.
- A transaction group accompanies every new sync change; page boundaries do not split a completion decision from its evidence/snag updates. Complete groups are applied atomically by future native pull integration. Existing manifests preserve their original coverage; new manifests include completion/review history.
- No optimistic closure. Uncertain review commands retain their exact UUID and payload. Conflicts require current evidence to be reviewed explicitly. Earlier attempts remain inspectable and do not become targets for the current pending decision.
- The connected review work is an unverified candidate until its database tests and actual browser review pass. Do not broaden its patterns or declare gates complete based only on TypeScript/controller checks.
