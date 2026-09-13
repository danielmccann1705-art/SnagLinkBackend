# Private staged import originals

This is an internal storage foundation for the selected-source staging contract in `STAGED-LEGACY-IMPORT-STORAGE.md`. It does not expose upload/download routes, register its migration, publish a canonical project, change the app, activate production, or validate an image/PDF. Original-file verification cannot close the complete import, drawing, sync or fresh-device release gates.

## Existing source and authority

`StagedImportOriginalService.retain` uses the current `StagedLegacyImportService.withActiveSession` transaction both before object IO and again before recording a measured receipt. It does not hold SQL locks across network IO. Current actor/auth version, account lifecycle, workspace role and immutable authority fingerprint, selected source/export, API origin/environment, device and expected session revision must still match. Aborted sessions are denied. Removing/rejoining a member or rotating an account's auth version invalidates the old preparation; an old receipt does not bypass current access.

The declaration UUID is a stable server-created row identity in `staged_legacy_import_files`. The server loads its expected SHA-256/byte count from that immutable declaration. No raw source path, caller storage key, cross-session hash lookup, historic user ID or contractor token can select a storage object.

## Separate operation namespace and measured fact

The dedicated idempotency namespace is **`staged-original-file-v1`**, not `mutation_receipts`. Its command binds the complete source/destination/device scope, declaration UUID, caller-retained operation UUID and expected session revision. The request digest also includes the server-loaded declared SHA-256 and byte count.

`staged_import_file_operations` reserves exactly one stable operation per session/declaration and one request per actor/operation before any object IO. A changed command, operation reuse for a different file, or a replacement operation for an already reserved file conflicts. Retain the original operation and source journal through retries. This bounded namespace cannot be used as a generic operation alias; existing canonical mutation lock ordering and receipt semantics remain unchanged. Its advisory lock is taken only under the current workspace lock, and has a separate name from global mutation locks.

`staged_import_original_receipts` is a separate immutable table with `(session_id,declaration_id)` foreign key and a matching file-operation foreign key. The receipt records the exact measured original hash/count, current server timestamp, original operation, actor/device and session revision. It has fixed verification `persisted_original_bytes_v1` and content validation `opaque_not_decoded`. Returned `canonicalReady` is always false. Declaration `unverified_declaration` rows and file-role edges never change.

Same-operation retries re-read the actual persisted bytes and return the original database receipt, including its ID/timestamp. They do not issue a new PUT after a receipt already exists. A missing/corrupt retained object fails closed for repair; it never authorises replacement of immutable originals. Cancellation near final SQL COMMIT is an uncertain outcome, not a rollback promise: replay the same command to discover the retained result under current authority.

## Storage and stream boundary

`StorageService.stagedImportOriginalStore` reuses its existing lazy Soto S3/AWSClient and separately configured private bucket. It fails closed without that private R2 configuration. Historical public storage, current photo keys, `privatePath`, image processing and local photo semantics are unchanged. Tests inject a private test store/HTTP transport. A real local-disk import store is not implemented.

The typed adapter derives this namespace entirely from server-controlled UUIDs:

`staged-import/<workspace UUID>/<session UUID>/<declaration UUID>/original`

No storage key or bucket is returned in the receipt. Store original bytes as `application/octet-stream`, with `Cache-Control: private, no-store`. Use Soto's real `PutObjectRequest.ifNoneMatch = "*"`; a 412 permits only actual readback verification, never overwrite. Other storage errors produce fixed identifiers/messages without provider exception text, URLs, source paths or keys. Soto logging remains disabled at this boundary.

The pinned Soto 7 SDK supports conditional PUT, streaming `AWSHTTPBody`, `S3.with(timeout:options:)` and `.s3DisableChunkedUploads`; the adapter disables AWS signed chunk framing for this R2 stream while reusing the shared client. Pinned Soto `RetryMiddleware` does not automatically retry streaming request bodies. Zero-byte PUTs can be retried by SDK policy, but remain conditional and immutable.

The input and persisted GET are counted and SHA-256 hashed incrementally. Bounds are 0…2 GiB per declared file, chunks no larger than 1 MiB, and one total cooperative 120-second IO deadline (including SDK retries and persisted readback). The final upload chunk is withheld until its hash/count and true stream EOF have matched. Zero-byte sources are explicitly checked before HTTP PUT, because zero-content-length clients may not iterate a body. ETag, Content-Length and object metadata are not byte-verification evidence. Sources must obey back-pressure and cancellation; a future HTTP adapter must not buffer an unbounded producer ahead of this reader.

An interrupted PUT or post-IO permission/cancellation failure can leave a private original without a receipt. Same-operation recovery can verify that object through conditional PUT/GET. No cleanup ever deletes/replaces an existing original during a retry. A storage-level failure or a server crash after object retention but before receipt is represented by the durable operation reservation, not a falsely completed session.

## Verification and remaining gates

On 13 September 2026 (UK time), the implementation compiled on macOS/arm64 and **23 unique focused tests passed, zero failures or skips**: 10 actual-Soto/stream tests, 12 original-file PostgreSQL tests, and one additional observed pre-commit cancellation/recovery test. The unchanged implementation was reused across the three runs; only the final cancellation test was added after the first two. The first two assembly digests were `86c776e3d0db8b6d55a9dd731504f28a2f4acd91b1068d9ab37c5840f0e75504`; the final source/test assembly was `f017604cdf855b2b7a338737f64dd4536b01f2ad6ef4d18897d9a41ef6d61b2a`. Source inputs were backend `90748aa3aaa58a8b84f191ea4e9b240c73c9a4c3`, the separately pinned integrated source-session/configure slice, and this original-file overlay. Existing Package.resolved pins were preserved. An initial pre-assembly/default-cache permission failure was retained separately; it ran no tests and is not part of the passing evidence.

Tests exercise the real pinned Soto request encoder/signing/error parser against an injected no-socket HTTP transport, plus isolated PostgreSQL authority/receipt tests. They cover zero bytes, final-chunk withholding, short/extra/wrong-hash bytes, oversized chunks and declared bounds, cancellation/deadlines, lost PUT responses/412 recovery, persisted readback mismatch, one immutable receipt under concurrent retries, wrong actor/device/source/revision/declaration, in-flight auth-version change, abort and admin removal/rejoin, immutable rows, and observed cancellation inside the actual receipt INSERT followed by same-operation recovery. They do not establish Cloudflare/R2 acceptance, native uploads, a public upload route or production readiness. Linux build and real R2 conditional-write behavior still need their own acceptance evidence.

Before public uploads: register/rehearse the additive migration; provide authenticated/CSRF-protected source-manifest and upload routes with stable declaration IDs; bind current native journals to the source session; implement explicit source withdrawal/retention and account/workspace erasure; and establish a compatible transport size strategy. **Internal 2 GiB file bounds do not prove a Worker can accept a 2 GiB HTTP body.** Use a separately verified multipart/chunked/resumable protocol or an honest conservative admission limit. Measure deadlines, memory and operational capacity with representative large files. No multipart upload, automatic cleanup scheduler or deletion/redaction lifecycle exists in this slice.

Before canonical publication: resolve all required roles, missing/unsafe files and historical graph findings; keep original retention separate from image/PDF validation and drawing provenance; implement verified drawing profile/lease/runtime/receipt flow, stable canonical mappings, collision handling and atomic publication; then complete native/browser synchronization and fresh-device/report parity. Historical closed statuses/authors remain explicitly unverified and cannot manufacture an accepted manager decision.
