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

Existing register, detail, review and contractor development samples are preserved. Real sign-in uses the same supplied wordmark, Plex typography, Marker/Ink/Stone tokens, controls and restrained layout. Development fixtures stay excluded from production output. The connected project header list is groundwork; it is not a completed connected register. D1 still needs a continuous recording and fresh native PDF comparison. D2 and the real iOS-to-second-manager close-out journey remain outstanding.

## Canonical writes and deletion

New v2 projects are explicitly platform-managed. Historical projects require a separately verified import; calling a read endpoint is not a migration. Both company projects and platform-managed personal projects reject legacy revisionless/snapshot writes. Existing unmanaged personal recovery paths remain available. The current canonical slice covers project creation and snag textual fields, references, publication and archive/restore; it does not yet cover complete project graphs, directory assignment, media or workflow commands.

Each canonical operation uses stable actor/operation/device IDs and a sorted payload hash. Successful responses are retained transactionally; a replay first rechecks current permissions. Reusing an operation ID with different work fails. Snag edits require a base revision, preserve absent fields and clear explicit nulls. Conflicts return the current permitted snag and changed fields. Generic edits cannot change state, ownership, assignment, evidence, reference or closedAt.

Logged snags use an audited, reasoned reversible archive. Their UUID/reference, evidence and accepted state remain; restore is explicit and revision-checked. A contributor can discard only their own unpublished draft; managers can archive logged work. Reference numbers are allocated under the project workspace lock and never recycled.

Change rows use a workspace counter advanced inside the same locked transaction, not sequence allocation order. The register snapshot service now freezes project/snags into bounded immutable pages and pairs its high-watermark with authenticated per-project deltas. Snapshot/cursor checks revalidate membership on every request; rejoining requires a fresh bootstrap. Coverage is explicitly project/snags, not complete device synchronisation. Directories, media, drawings, completion history and migration must join the full graph contract before WP-03 or G1 can pass.
