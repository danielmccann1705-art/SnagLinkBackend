# Private staged original file HTTP — version 1

This adds authenticated file discovery and bounded original-byte upload for the retained selected-source session described in `STAGED-LEGACY-IMPORT-HTTP.md` and `STAGED-IMPORT-ORIGINALS.md`. It remains explicitly development/staging only under `STAGED_LEGACY_IMPORT_ENABLED=true`; production is rejected even when the flag is true. Adding these files sets no runtime flag and deploys nothing. Source preparation, file storage and canonical publication remain distinct.

## Current authority and revocation

Both routes use PlatformAuthMiddleware (native bearer JWT or a current browser session), the source-session nonproduction gate, exact source/API/workspace/device binding and original importing actor. Browser POST reads also require the allowed Origin and X-CSRF-Token. The shared `StagedImportRequestBoundary.actor` contains the prior source controller's unchanged reauthentication after metadata decode; it never upgrades an old request to a new authVersion by loading a newer user.

**The new original upload additionally reauthenticates the same request after object IO.** `StagedImportOriginalService.retain` invokes its required public-route callback inside the final `withActiveSession` transaction. Current user/auth generation and workspace locks are already held. For browser requests, the callback rechecks current cookie/Origin/CSRF and locks the same unrevoked, unexpired browser-session row FOR SHARE until the measured receipt commits. The lock order is workspace → current user → browser session. `BrowserSessionService.revokeAll` writes user generation before browser sessions; single-session `revoke` writes only its session. A revoke completed before the receipt lock blocks the receipt. A revoke arriving after that shared lock waits for the already-authorised receipt transaction to finish. Expiry is checked at that authentication point, not promised continuously after it.

The optional callback defaults to nil only for established internal original-store consumers/tests; the public upload handler always supplies it. **Existing source create/read/abort retain their prior in-flight semantics:** they reauthenticate after bounded body decoding and hold current account/workspace authority during storage, but do not lock a browser-session row through that transaction. This slice does not claim a new central revocation guarantee for unrelated routes.

## File manifest

`POST /api/v2/workspaces/:workspaceId/import-sessions/:sessionId/files/manifest`

Content-Type application/json. No query or Content-Encoding. Maximum body 16 KiB. Closed root fields:

- `formatVersion`: integer 1.
- `scope`: exact existing source scope (`sessionId`, `workspaceId`, `deviceId`, `destination`, `exportSHA256`, `sourceFingerprint`, `selectedProjectId`). Route IDs must match; origin/environment/digests are validated.
- `expectedSessionRevision`: positive and equal to current active preparation revision.
- `offset`: 0…20,000 and not beyond the source declaration count.
- `limit`: 1…100.

Response fields: `formatVersion`, `scope`, `sessionRevision`, `totalCount`, `offset`, optional `nextOffset`, `descriptorMaximumBytes` (8,388,608), `totalDeclaredFileMaximumBytes` (2,147,483,648), `singleRequestMaximumBytes` (52,428,800), `supportedContentType` (application/octet-stream), `supportedOriginalRoles`, `canonicalReady` (always false), and `entries`.

Each entry contains `declarationId`, server `ordinal`, `handleDigestVersion` (1), `sourceHandleSHA256`, `declaredSHA256`, `declaredBytes`, optional `operationId`, optional `originalReceipt`, `storageState`, and `uploadSupported`.

Storage states are `declared_only`, `operation_reserved`, or `persisted_original_verified`. The receipt is the established immutable original receipt, retaining its original ID/time/operation and `canonicalReady=false`; it describes a measured fact and does not perform a new R2 GET during manifest reading. `uploadSupported=false` keeps an original above the initial single-request limit visible, even if an earlier internal process had retained a measured receipt. Never truncate, resample, omit or silently complete the import because a file is unsupported.

The handle digest is exactly:

`SHA256(UTF8("snaglist-staged-source-handle-v1\n") || UTF8(archivePath))`

The `\n` denotes one newline byte. No Unicode normalisation is performed. The native client derives it from its freshly verified retained source handle and matches only inside the exact source/export/session, also checking declared bytes/hash. SQL `COLLATE "C"` defines stable server pagination over immutable declarations. Native must not reproduce SQL sorting: its Unicode string ordering may differ. Ordinals are page positions, not file ownership or portable identity.

No source path, filename, storage key, public URL, contact, comment or raw historic record is returned. A physical declaration can have several retained source uses; the upload does not collapse or alter those role-use edges. The supported original roles are projectCover, photoOriginal, photoThumbnail, photoAnnotation, drawingFile, drawingThumbnail, commentAttachment and deletedPhoto. Every uploaded file remains opaque bytes; MIME validation, image/PDF decode, drawing provenance and canonical role attachment are later facts.

A reserved `operationId` must be resumed exactly. In its absence, native creates and durably retains one before the first upload, bound to the same verified source/account/workspace/API/device/session/declaration. An uncertain response is resolved through this manifest and the same operation. Do not replace a reserved operation, infer a match solely from a cross-source content hash, or attach work to the next signed-in account.

## Raw original upload

`POST /api/v2/workspaces/:workspaceId/import-sessions/:sessionId/files/:declarationId/original`

Required metadata:

- Exactly one `X-Snaglist-Import-Command` header, canonical padded Base64 of at most 4 KiB decoded JSON. Closed envelope: `{formatVersion:1, command:{scope,declarationId,operationId,expectedSessionRevision}}`. Exact scope keys are as above; URL IDs must match. Duplicate/escaped duplicate keys, extra authority/storage fields, malformed Base64, unsupported nesting and oversized data fail closed.
- Exactly one canonical decimal Content-Length from 0 through 52,428,800, with no signs, spaces or leading zeros except `0`.
- Exactly one application/octet-stream Content-Type; no content encoding, transfer encoding, query or multipart form.

The server loads the immutable declaration under current source authority and checks the declared size against the HTTP cap and Content-Length **before inserting a file-operation reservation or reading a nonempty body**. Headers do not assert verified bytes. The internal original-store limit/default remains 2 GiB for its separate contract.

The handler is registered with `body: .stream`. It passes pinned Vapor Request.Body's back-pressured AsyncSequence into Soto's lazy HTTP body; it does not collect large originals. The existing original service enforces per-chunk/declared-count/hash/EOF checks and a cooperative 120-second IO deadline. For zero bytes, `body.collect(max:0)` safely verifies an actual empty body before constructing the empty stream, avoiding Vapor's `.none` AsyncSequence precondition. No custom unbounded producer is introduced.

Original namespace derives only from current workspace/session/declaration UUIDs. Conditional If-None-Match PUT, actual private persisted GET/hash, and same-operation receipt replay are unchanged. A failed/aborted/revoked transfer may leave a private original and durable reservation without a receipt. A retry must use that original identity; neither a failure nor a corrupt/missing object permits overwriting retained bytes.

Success is HTTP 200 with only the immutable StagedImportOriginalReceipt and no-store, no-referrer, nosniff, Vary Cookie/Authorization. This verifies original retention, not canonical media, validated drawings, accepted closure or an imported project. No object-download route or public object URL is added.

## Admission errors and capacity

401/403/404 reflect current authentication/CSRF/source access. 409 preserves stale/reused operation, revision, source or destination conflicts. 410 rejects an aborted preparation. 411 requires an exact Content-Length. 413 `staged_original_transport_limit` preserves unsupported originals and rejects the current transfer; malformed metadata is 400 (`invalid_staged_file_envelope` or the reused closed source-envelope error). A declared-length disagreement is 400 `staged_original_length_mismatch`; actual hash/byte mismatch remains 422. Timeout/storage errors use the existing fixed original-service identifiers without provider exception strings or source paths.

The 50 MiB initial cap matches current canonical PDF-source admission while existing image validation stays 10 MiB. Cloudflare request-body limits depend on the account plan, not simply paid Workers; current documentation lists 100 MB for Free/Pro and higher for other account plans. Worker memory is 128 MB. This implementation is a conservative admission choice and must be verified through the real deployed proxy; an internal 2 GiB declaration is not proof of a public 2 GiB upload. [Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/)

The established Worker proxy forwards request/response bodies without collecting them; keep that property. Same-origin portal requests require no new CORS header allowance; native URLSession does not use browser CORS. No unrelated CORS policy has changed. Multipart/resumable transfer for larger originals, per-account operational admission, retention/withdrawal/redaction/account-deletion policy, orphan cleanup and production activation remain separate gates. Canonical publication still requires all mandatory roles, drawing/profile/lease validation, stable mappings, atomic publication and native/browser/fresh-device/report parity.

## Verification status

On 13 September 2026 the exact implementation compiled on macOS/arm64 against backend commit `16f8df16da37b07942dbf2d4937e266b8344f461`, the separately pinned integrated original-storage dependency and unchanged resolved package pins. **46 distinct targeted tests passed with zero failures or skips:**

| Suite | Passed | Observed coverage |
| --- | ---: | --- |
| `StagedImportFileWireTests` and `StagedLegacyImportWireTests` | 11 | Closed schema, duplicate keys, metadata and byte limits, URL/source binding, exact UTF-8 handle digest, existing source envelopes |
| `StagedImportFileHTTPTests` | 7 | Manifest paging and private mapping, lost-response operation recovery, real loopback 50 MiB and empty uploads, oversized declarations, authentication/CSRF, abort and production gate, browser revocation after IO and a PostgreSQL-observed revocation lock through receipt commit |
| `StagedLegacyImportHTTPTests` | 5 | Existing source create/read/abort, lost-response retry, current account/company scope, opaque receipt isolation, browser authentication and production gate after shared-helper extraction |
| `StagedImportOriginalServiceTests` and `StagedImportOriginalTransportTests` | 23 | Current actor/device/source/revision fences, abort/revocation/cancellation during IO and receipt insertion, immutable operation/receipt replay and concurrency, pinned Soto conditional PUT/readback, empty/short/excess/wrong-hash streams and bounded cancellation/deadline behavior |

The HTTP/database suites used isolated local PostgreSQL with the real `configure.swift` registration of source and original-receipt migrations. No manual fallback migration was added to the tests. Large/empty uploads and the two browser-revocation cases used actual loopback HTTP sockets; the remaining HTTP cases exercised Vapor's in-memory routing. Object storage was the pinned Soto client with an injected synthetic HTTP transport, not a live R2 account. The receipt-lock test observed both the paused receipt insertion and a blocked browser-session revocation before successful commit; a subsequent request with the revoked cookie was denied.

Task-local reports `wire-compile-2.json`, `http-1.json`, `source-http-1.json` and `originals-1.json` share source assembly SHA-256 `a2993785062ea30d5f88dce28793bbbcef3facf8397904b966ab4ccf57f6ccfe` and resolved-pins SHA-256 `73662f28607595910f57af43c7b04ba4489b7e61ef38938f32888bbd110fc268`. The earlier successful wire compile remains separate evidence; it is not counted twice. The accompanying task manifest records exact per-file, report and log hashes. Documentation-only updates after these checks do not alter the tested source assembly.

Actual staging/proxy/R2 upload, browser-selected upload, native file transfer, Linux compilation, public-network interruption recovery and production activation remain unverified. Local passing tests do not establish those acceptance gates. Unsupported originals above 50 MiB and incomplete canonical/drawing processing remain visible blockers to complete import.
