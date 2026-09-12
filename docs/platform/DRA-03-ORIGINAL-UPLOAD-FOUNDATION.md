# DRA-03 — initial upload authority and measured-original receipt foundation

Prepared 12 September 2026 over backend `aae8e42098498ae50c70b78ba17fe58283e46038`. **Implemented and verified in the local backend: 43 tests passed across three targeted suites, with zero failures or skips.** No HTTP route, provider change, parser execution, connected Worker bridge, deployment or drawing capability is established by this checkpoint.

## Behaviour

[`CanonicalDrawingService.allocateWithExpectedRuntime`](../../Sources/App/Services/CanonicalDrawingService.swift) is an explicit internal opt-in. It requires a selected existing workspace, current managed project/editor authority and server-selected `DrawingProcessorRuntimeIdentity`. New allocations retain that exact profile. Its idempotency fingerprint includes workspace, profile and expected image digest; changing selection under the same operation conflicts. Existing `allocate()` retains its placeholder `drawing-initial-v1`, request fingerprint and behaviour. An old allocation is never relabelled, and the new opt-in cannot silently attach an unscoped legacy project.

The expected image digest is configuration and request identity, not evidence that an image was run. The receipt and source retain the processor profile; they do not claim observed image execution. Public use of the opt-in still requires the runtime/isolation acceptance gate.

Only the opt-in allocation takes an operation advisory lock, then the selected workspace advisory lock, then the actual project row `FOR UPDATE` before checking scope/managed state and entering the older access helper. The row lock remains until the transaction inserts its immutable source/FK or rolls back. A concurrent direct writer changing workspace to NULL must finish before this check or wait until after the source exists; the helper cannot silently adopt a project between the check and insert. This order matches the modern platform mutation order in [`PlatformProjectController.create`](../../Sources/App/Controllers/PlatformProjectController.swift). The historical unscoped branch of [`ProjectAccessService.require`](../../Sources/App/Services/WorkspaceAccessService.swift) can save a project before its workspace lock; it is unchanged and is never entered by this opt-in. This is a narrow no-adoption guarantee, not a claim that every legacy transaction has a uniform lock order; PostgreSQL may reject an incompatible legacy interleaving as a deadlock.

[`DrawingOriginalVerificationService.requireCurrentUpload`](../../Sources/App/Services/DrawingOriginalVerificationService.swift) checks the initial allocated-uploader phase. It takes the expected workspace lock, verifies the actual immutable source before using the shared access helper, and checks current actor/editor/uploader, purpose, exact source/profile and allocation expiry. It returns an internal derived original read target; keys cannot be supplied by a caller and must never be exposed through HTTP.

`verifyStoredOriginal` first checks authority, then asks a trusted `DrawingOriginalObjectReading` implementation to read the **persisted private original**. The interface pulls chunks up to 64 KiB with no whole-file collection; the verifier computes SHA-256/count itself and checks MIME metadata plus the same minimal framing checks as DRA-02 `verify_source`. Reader implementations must not substitute an upload request body, supplied checksum or parser assertion. There is no client-Decodable measured-proof input and the internal measured value can only be constructed by the byte-reading code.

These framing checks are not complete PNG/JPEG/PDF validation. Tests deliberately identify their small byte fixtures as framing-only. Structure, encryption, unsupported filters, geometry, pixel bounds and parser confinement still belong to the separate isolated processor.

After reading, authority is checked again in a new database transaction. The measured receipt is inserted and the source revision increments atomically. The source stays **allocated**; there is no new `uploaded`/`ready` state or inferred publication. One immutable receipt exists per asset. Concurrent/exact retries re-read actual stored bytes and return the original receipt time/revision. Once processing has started, initial upload authority fails; a pre-existing receipt may be reverified while source state is processing/ready, current uploader/edit access remains and allocation expiry has not passed. A job started without a receipt cannot create one retroactively. Historical receipt/download APIs are not implemented.

The original allocation expiry bounds every verification attempt, including a replay with an existing receipt. Expiry denies another readback/reverification; it does not expire/delete the historical receipt, reset its time/revision or change the source's allocated/processing/ready state. The service does not expose a separate historical-receipt retrieval operation after that window. This differs intentionally from the existing completed-processing-result replay contract, which may return a matching ready result after lease expiry while still checking current access.

## Migration and durable records

[`CreateDrawingOriginalReceipts`](../../Sources/App/Migrations/CreateDrawingOriginalReceipts.swift) is an additive migration registered immediately after canonical drawings. It adds only `drawing_original_receipts`: asset/workspace/project/uploader, measured SHA/size/MIME, profile, verification method, server time and resulting asset revision. Composite scope FKs and a before-insert trigger match the receipt to the immutable allocated source. A trigger rejects receipt updates/deletes; the down migration explicitly refuses destructive removal. Existing source/page/version/photo tables and their data are not rewritten.

Receipt writes do not create a processing job, page, publication, graph journal entry or synchronisation acknowledgement. Existing `beginProcessing` is unchanged and does not independently require this new receipt; the future trusted coordinator must connect verified-source prerequisites before exposing dispatch. The reader-to-Worker/R2 transport remains an explicit implementation gap.

## Local verification — 12 September 2026

The new test class is [`DrawingOriginalVerificationTests`](../../Tests/AppTests/DrawingOriginalVerificationTests.swift). Its 15 passing cases cover:

- Existing placeholder allocation compatibility, explicit profile selection and changed-profile replay conflicts.
- A concurrent direct workspace-to-NULL write: observe the actual project row-lock wait, then reject without legacy adoption, drawing source or mutation receipt.
- Actual chunk hashes/counts/framing and source revision without drawing readiness.
- Concurrent receipt idempotency and receipt replay after a lease begins.
- Stored hash/size/MIME/signature mismatch, provider-error sanitisation, cancellation and oversized chunks.
- Wrong scope/actor/Viewer, removal during readback, archive, expiry and premature processing.
- No implicit legacy claim or placeholder relabelling, immutable receipt update/delete rejection, duplicate migration/revert refusal and cross-scope insert rejection.

The compiled tests ran against isolated local PostgreSQL with synthetic fixtures and the current migrations. The report case lists were independently compared with their complete logs; all counts match. The tested `Sources`/`Tests` assembly SHA-256 is `1bf08b0a25b5d6ea4bae93051333251e46dfcbe3a6aab075041694b96831465f`, over the baseline commit above. The five Swift files in this change match that tested assembly byte-for-byte; only this evidence document was updated after the runs.

| Suite | Passed / failed / skipped | Completed UTC | Evidence report SHA-256 |
| --- | --- | --- | --- |
| `DrawingOriginalVerificationTests` | 15 / 0 / 0 | 2026-09-12 20:12:50 | `ecf2b0e1109d5ffb1939fbbe12998b6db79e9efec1ba3174386106883c9d7be0` |
| `CanonicalDrawingTests` | 17 / 0 / 0 | 2026-09-12 20:13:23 | `7411283f9ebb1fa8684ad1cc2aab4313efe5732f3dddb963ca07bee285f6f1f2` |
| `DrawingProcessingAuthorityTests` | 11 / 0 / 0 | 2026-09-12 20:13:57 | `626f6542b5f1dc2467f3f95b701b5ecd504b3fb7b3db54d4efc0ec59f9268b9a` |

The coordination handover retains `test-results.json`/`tests.log`, `canonical-drawings.json`/`canonical-drawings.log` and `processing-authority.json`/`processing-authority.log` under `work/drawing-upload-authority`; the source manifest pins every report and log. These are dated local evidence, not remotely verified capabilities. The first build logged one existing dependency-packaging warning for an unhandled file in `jwt`; it compiled successfully. No broader unchanged test suite was rerun.

The allocation race test requires two test-database connections. Its writer transaction allows up to 250 polls of same-user `pg_stat_activity`, with 20 ms pauses and an 8-second per-statement timeout, and clears the statistics snapshot between polls. It asserts a lock wait on the identified allocator query rather than treating a delay alone as evidence, then commits only its own synthetic NULL-workspace fixture and awaits allocator rejection. This test passed in 0.507 seconds and confirmed no source, mutation receipt or implicit workspace adoption. It exercises the concrete legacy/direct-write interleaving; it is not an exhaustive deadlock or database-load test.

No remote storage, image build, new migration rehearsal against an old backup, or provider runtime check has run for this overlay. Before staging promotion, rehearse the new additive migration on the isolated restored backup, verify existing rows/columns and migration ledger, and exercise the real stored-object reader. The earlier 24 Node/10 local workerd results apply only to their unchanged, separately pinned storage foundation; the 11 processing-authority tests were additionally rerun against this combined receipt/allocation change as recorded above.

## Remaining activation gates

1. Implement and verify a real private-object reader and immutable original upload transport. The interface's deadline is checked before/between chunks, and cancellation closes owned IO; a future reader must enforce the deadline during blocked open/read calls. This foundation does not claim a hard network timeout or an R2 binding.
2. Join explicit runtime-profile allocation, measured-original receipts, current processing leases, authenticated internal Worker/backend control, durable dispatch, bounded retry/failure and reference-aware orphan cleanup. Keep all service/database/R2/session credentials and lease tokens outside the untrusted renderer.
3. Prove a single-job Cloudflare-compatible sandbox with parser DNS/network denial, filesystem/process isolation, bounded scratch/PIDs/resources/output and non-cooperative descendant termination. `enableInternet=false` and the local Docker flags are not proof of equivalent provider isolation. Changes to wrapper/sandbox/runtime require new exact source/profile/image acceptance.
4. Verify original and all processed output bytes, immutable source/profile, manifest geometry and current lease before atomic readiness. Then implement private gateways, publication acknowledgement, Contractor page/PIN/revocation scope, complete graph projection, native import/sync and four-surface coordinate checks.

The [canonical drawing specification](CANONICAL-DRAWING-IMPLEMENTATION-SPEC.md), [DRA-02 processor report](DRA-02-BYTE-PROCESSOR.md) and [private drawing foundation](../../Infrastructure/drawing-processor/README.md) remain the surrounding contracts. This foundation neither weakens those gates nor activates them.
