# Private selected-source session HTTP — version 1

Backend prerequisite: `f60368ac785d8421a38c98be3a5cdb388055de0a`. This HTTP overlay passed 6 wire and 5 actual local HTTP/PostgreSQL tests with no failures/skips; it is not deployed.

This stage stores the complete selected export privately. It creates no canonical project, uploads no media, verifies no historical author/approval and cannot commit an import. The diagnostic preview remains separate and is not required to be unexpired before a retained source-create retry.

All routes use `PlatformAuthMiddleware`: native bearer JWT or current browser session. Cookie-authenticated requests, including receipt reads, require the current allowed Origin and X-CSRF-Token. The controller checks the current authenticated principal again after body decoding and never upgrades an old request to a new authVersion by reading a newer profile. Current account generation, workspace membership/owner revision, explicit device/source/API bindings and original importer are checked by the storage transaction.

The route exists only as disabled-by-default code until `STAGED_LEGACY_IMPORT_ENABLED=true` is explicitly configured. That opt-in permits only `development` or `staging`, as validated by the existing `ImportServerBinding`/`PlatformConfiguration`. Production is rejected even if the flag is true. Existing explicit `IMPORT_PREVIEW_API_ORIGIN` supplies the API identity for both source preparation and previews; the portal origin/Host header never supplies it. This change installs no environment flag/provider setting or production activation.

## Create

`POST /api/v2/workspaces/:workspaceId/import-sessions`

Content-Type `application/json`; no Content-Encoding and no URL query. Maximum collected and decoded-envelope size **12 MiB**.

Root fields are exactly `formatVersion` (integer 1), `command` and `descriptorBase64`. The command fields are exactly:

| Field | Value |
| --- | --- |
| `sessionId` | Retained client-generated UUID for this private staging session. |
| `mutation` | Exactly `operationId` and `deviceId`, UUIDs. The distinct create-stage operation must not reuse the diagnostic preview operation. |
| `expectedActorId` | Explicit selected stable account UUID; must equal current authenticated actor. |
| `expectedWorkspaceKind` | `personal` or `company`, matching the actual workspace UUID in the route. |
| `destination` | Exactly `environment` and canonical `apiOrigin`, matching the configured API identity. |
| `selectedProjectId` | Stable UUID from the selected export. |
| `sourceFingerprint` | Lowercase SHA-256 archive source fingerprint declared in that exact export. |
| `exportSHA256` | SHA-256 of exact decoded descriptor bytes. |
| `exportByteCount` | Exact decoded byte length, 1…8 MiB. |
| `acknowledgement` | Exactly `version`, `wording`, `accepted`. Explicit accepted=true; exact current constants below. |

No client `authVersion` or nested command `formatVersion` is accepted. The controller constructs the internal service command's authVersion from the freshly authenticated server context.

Acknowledgement version: `selected-source-staging-v1`.

Exact acknowledgement wording:

> I am authorised to transfer this selected project's data to the selected workspace. Prepare this source privately for import. Historical names, statuses and closure are unverified; this preparation does not publish a project or approve work.

`descriptorBase64` is standard, canonical padded Base64 of the **exact** immutable native export bytes. The decoder rejects URL-safe alphabet, whitespace, omitted/extra padding, non-zero pad-bit aliases, and an encoded/decoded length that disagrees with exportByteCount. The envelope may use ordinary valid JSON escaping; the decoded source bytes are never re-encoded as JSON for their digest. Retain the first complete request bytes and session/device/operation IDs before transmission; do not regenerate them after an uncertain response.

All envelope/nested objects have closed keys. Duplicate keys (including Unicode-escaped aliases), arrays, excess depth (>6), excess nodes (>128), missing/null required values, trailing JSON and out-of-bounds payloads fail before service publication. The source's separate strict v1 decoder verifies its complete 187-field schema, all graph/role bounds and source digest.

## Read receipt and abort

`POST /api/v2/workspaces/:workspaceId/import-sessions/:sessionId/receipt`

Body exactly `{formatVersion:1, scope:{...}}`. This is a side-effect-free read through POST so fingerprints and device bindings do not enter query URLs or browser navigation history; cookie CSRF still applies. Maximum body **16 KiB**.

Scope fields exactly `sessionId`, `workspaceId`, `deviceId`, `destination`, `exportSHA256`, `sourceFingerprint`, `selectedProjectId`. UUIDs must be valid, URL session/workspace must equal scope, destination is canonical, digests are lowercase SHA-256.

`POST /api/v2/workspaces/:workspaceId/import-sessions/:sessionId/abort`

Body exactly `{formatVersion:1, scope:{...}, mutation:{operationId,deviceId}, expectedRevision}`. Maximum 16 KiB. Positive revision; mutation device must equal scope device. The abort action has its own retained operation UUID. Exact retry is safe; a new abort against an already aborted or stale revision conflicts. Abort keeps source bytes and mappings; it is not erasure or remote snag deletion.

## Response and retry semantics

All successful operations return HTTP 200 and `Cache-Control: no-store`, with the existing `StagedLegacyImportReceipt` JSON. Dates are server ISO-8601 strings at whole-second encoding precision. There is no `expiresAt`/automatic expiry in this source stage.

Receipt fields: `formatVersion`, `sessionId`, `createOperationId`, `deviceId`, `actorId`, `workspaceId`, `workspaceKind`, `destination`, `selectedProjectId`, `sourceFingerprint`, `exportSHA256`, `exportByteCount`, `requestHash`, `state`, `revision`, `recordCounts`, `edgeCount`, `fileRoleCounts`, `declaredFileCount`, `declaredFileBytes`, `sourceIssueCounts`, `journalEventUpperBound`, `snapshotRowUpperBound`, `acknowledgementVersion`, `acknowledgedAt`, `createdAt`, `updatedAt`, `importExecutable`, `mediaVerification`, `historicalAcceptance`.

`requestHash` is an **opaque server-normalised request digest** including server auth generation. Native keeps its exact first-wire SHA separately; it must not invent this server hash. Validate the explicit account/workspace/device/API/source/session/create-operation bindings, supported states/counts/digests and server date relationships.

States: `staged_incomplete`/revision 1, or `aborted`/revision 2. Always `importExecutable=false`, `mediaVerification=source_declarations_only`, `historicalAcceptance=unverified_no_canonical_decisions_created`. A successful create retry returns the current state, including aborted; it never reactivates or duplicates the source. Read/abort never return source bytes, contacts, names, media URLs, filenames or raw historical records. Stable per-file declaration IDs and a private bounded upload manifest belong to the next file-transport step.

Ordinary reauthentication of the same account can resume when the backend authVersion and current authority are unchanged. Logout-all/authVersion change or membership/owner revision changes block the existing stage even after a new login. No automatic reauthorisation, ownership transfer or device-ID replacement exists. An expired diagnostic preview does not revoke the separate source stage. When cancellation reaches the server Swift task before the final storage fence, it rolls back. An HTTP disconnect or URLSession cancellation does not prove that server-task cancellation propagated: preparation may finish without a response. Keep this outcome pending under the original actor; a cancellation racing COMMIT is likewise resolved by the same retained operation.

## Errors and acceptance boundaries

- 400 `invalid_staged_import_envelope` or `invalid_staged_import_source`: closed schema, unsupported metadata/base64/source shape. No raw values are reflected.
- 401: missing, expired, revoked or stale-generation authentication; original request must not be attached to the next account.
- 403: current owner/admin or browser Origin/CSRF requirement failed.
- 404: workspace/session unavailable to this actor, including another current company manager's private preparation.
- 409: source-byte mismatch, changed operation/body/device/destination/authority or stale abort revision. Preserve local archive and exact first request.
- 413: 12 MiB/16 KiB route cap, decoded source size or complete graph/publication/retention bounds. No truncation or partial source publication.
- 503 `staged_import_disabled`: no explicit non-production opt-in. Missing configured API identity also remains a service-unavailable error.

This transport is authorised only for synthetic isolated development/staging. Real-data/production activation still requires explicit source withdrawal/retention/redaction/account-deletion policy, bounded authenticated upload operations and operational safeguards. No raw source dump endpoint exists. Keep descriptors, filenames, contacts, GPS, history and credential-bearing values out of request logs and analytics. Ordinary app → full file import → canonical publication → portal/fresh device/report acceptance remains incomplete.
