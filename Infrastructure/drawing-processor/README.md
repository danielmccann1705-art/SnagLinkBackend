# Private drawing storage and processing authority

Status: **internal foundation, locally tested; drawing uploads and processing are not enabled by these files.** Prepared 12 September 2026. The released app remains separate from this working-branch capability.

## What is implemented

[`drawing-store.mjs`](drawing-store.mjs) is an internal Worker-compatible R2 adapter. It accepts a server-verified allocation and a required current-authority callback. It derives private keys from workspace/project/asset UUIDs, keeps drawing objects separate from capture/completion media, streams bounded writes with conditional no-overwrite and SHA-256 checks, and hashes actual stored bytes before acknowledgement. Matching originals/pages can be reused on retry; mismatched existing bytes conflict and are never silently replaced or deleted. Concurrent conditional writes and interrupted streams release both sides of the bounded stream. Returned results attest object bytes only; they contain no storage key or ready-state claim.

[`DrawingProcessingAuthority.requireCurrent`](../../Sources/App/Services/DrawingProcessingAuthority.swift) is the server-side permission check for **already-leased processing**. Under the current workspace transaction lock it checks the active actor, project edit permission, uploader, exact workspace/project/asset/source/profile identity, processing state, current lease token, attempt and source/lease expiry. It returns no storage key or lease token. Unscoped legacy projects fail before the older access helper can attach them to a personal workspace. The initial upload of an allocated original has no processing lease and needs a separate uploader/allocation authority check.

These are independently tested pieces, **not a connected storage/lease coordinator**. No caller currently joins the Worker callback to this server predicate. The returned authority scope is a point-in-time result, not a signed grant, durable byte-verification receipt, session verifier or runtime attestation. It must be checked before and after storage IO; final completion still requires the existing database transaction. Never hold a database transaction open across network IO.

## Source-specific verification

The final checks below used synthetic data on 12 September 2026. No remote R2 or parser-runtime acceptance is claimed.

| Check | Actual result | Source and scope |
|---|---|---|
| Node storage tests, 19:06:46 UTC | **24 tests passed**, zero failures | [`tests/drawing-store.test.mjs`](tests/drawing-store.test.mjs); injected streams/R2 double. Covers checksum/size/MIME mismatch, concurrent retry/collision, cancellation, changed authority and purpose/profile bounds. |
| Local workerd/R2 emulation, 19:13:58 UTC | **10 assertions passed**, runtime disposal confirmed | Pinned Miniflare `5.20260911.0-alpha`; actual Workers DigestStream/FixedLengthStream and ephemeral local R2. Confirms conditional concurrency, checksum rejection, actual readback, page objects and changed authority. The task-local harness is not a deployable Worker and is not included here. |
| Isolated PostgreSQL integration, completed 19:30:49 UTC | **11 tests passed**, zero failures or skips | [`DrawingProcessingAuthorityTests.swift`](../../Tests/AppTests/DrawingProcessingAuthorityTests.swift), assembled over backend `78ad83aeb423cdf21c6c7b4083a5a8ef513bdfa9`. Covers personal/company scope, source/profile mismatch, absent/completed/expired/replaced jobs, removal/Viewer downgrade, archived project/disabled user, legacy preservation and workspace FK protection. Synthetic source/job fixtures do not represent actual uploaded bytes. |

Earlier development attempts exposed a stream-cancellation deadlock, outdated Miniflare constructor options and two test-fixture capture errors. These were corrected before the final respective runs. Their failed records remain retained separately; they are not passing executions.

Verified product/test bytes:

| Repository-relative file | SHA-256 |
|---|---|
| `Infrastructure/drawing-processor/drawing-store.mjs` | `ed5f62f2fcb68864523b6b8d0e9d2669ece49a82d61efd1aa0e8bf2608e6740d` |
| `Infrastructure/drawing-processor/tests/drawing-store.test.mjs` | `a96d67f9731527efbadd622d5d240fa88b04b21a0ea6ca063a2e9cbb743d5fa3` |
| `Sources/App/Services/DrawingProcessingAuthority.swift` | `aa87a8988db25bf701a92bfcffcf6061e66be67a7929a041e1167e93423a6421` |
| `Tests/AppTests/DrawingProcessingAuthorityTests.swift` | `0472c43c36d566dfe74b1b85459689fef185d4b15beff8b9e3cb5c7b87b79aa8` |

The assembled database-test source fingerprint was `6832ed831ae9af9e2464dfefeae75829201306f07c4fc3e1ff4a24202d4aaf0f`. Changes to these inputs require relevant new verification; do not present these results as a later full-repository rerun.

Run the portable Node tests from the repository root:

```sh
node --test Infrastructure/drawing-processor/tests/drawing-store.test.mjs
```

The database filter is `DrawingProcessingAuthorityTests`, using the established isolated PostgreSQL harness and current migrations. It requires an explicitly isolated synthetic database; no production or staging credentials belong in this directory.

## Permission and lifecycle boundaries

Current job lease columns are `NOT NULL`; the existing job states are `processing` and `complete`. Completion retains token/expiry and reclaim replaces them. An allocated source may have no job row. The authority lookup uses a left join and rejects missing/non-processing state before optional lease decoding, returning the named authority conflict for NULL joined values. No cancelled-job lifecycle is implemented.

The authority check takes the expected workspace lock before reading scope and requires an actual drawing source before calling `ProjectAccessService.require`. Its non-cascading composite project/workspace FK and source update/delete trigger prevent that referenced project's workspace from changing or becoming NULL. This is protection afforded by an existing immutable drawing source, not a general immutable-workspace rule for all projects. Any future project-transfer implementation must revisit it. Rejoining is governed by current ACL and lease; there is no independent membership-generation cancellation guarantee.

## Remaining dependencies, in order

1. **Original allocation and durable byte identity.** Existing `CanonicalDrawingService.allocate` still pins the placeholder `drawing-initial-v1`. Select a reviewed exact runtime/profile for new allocations; never relabel an immutable old allocation. Add the initial uploader/allocation upload check, a private drawing binding, actual signature/byte verification and durable measured-source receipts. Existing photo storage must not be broadened into a PDF path or used as a public-bucket fallback.
2. **Trusted dispatch and lease bridge.** Establish authenticated internal control between the Worker coordinator and backend; Vapor cannot directly consume a Worker service binding. Bind each job to source identity, profile and current server lease, with durable dispatch/deadline, bounded failure/retry state and reference-aware orphan cleanup. The renderer must not receive R2/database/session/service credentials or lease tokens. No public client may supply a trusted processing manifest.
3. **One-job runtime isolation.** Use a separately controlled instance per attempt; do not assume a Docker daemon inside Vapor. `enableInternet=false` alone is insufficient evidence of complete parser DNS/network isolation: DNS remains a specific acceptance gap. Prove denial of parser network syscalls/DNS and same-UID process/file attacks, plus read-only filesystem boundaries, bounded scratch, PID/CPU/memory/output limits and non-cooperative descendant termination on the chosen Cloudflare runtime. Do not assume the local Docker flags are provider startup options. A fail-closed in-image sandbox or proven equivalent is still required.
4. **Exact byte processing and atomic readiness.** The existing DRA-02 local processor is separately tested. Any IO wrapper/sandbox changes its runtime/profile inputs and needs a new pinned image/profile plus the full relevant parser fixtures. Validate original, manifest/geometry and every output object, then recheck current authority/lease and invoke transactional completion. Object checksums or successful container startup alone are not drawing readiness.
5. **Product integration.** Implement manager drawing routes, private range/read gateway, explicit full-source sharing acknowledgement, Contractor page grants/PIN/revocation, graph journal/bootstrap/delta, native import/sync and four-surface coordinate acceptance. Contractor links never inherit access to the whole source PDF. No endpoint, allocation/profile rollout, source receipt, working dispatch/runtime/lease bridge, drawing capability or complete recovery is delivered by this foundation.

See the [canonical drawing specification](../../docs/platform/CANONICAL-DRAWING-IMPLEMENTATION-SPEC.md), [DRA-01 foundation](../../docs/platform/DRA-01-IMPLEMENTATION.md), [DRA-02 byte processor](../../docs/platform/DRA-02-BYTE-PROCESSOR.md), [processor package](../../Tools/DrawingProcessor/README.md) and [existing transaction service](../../Sources/App/Services/CanonicalDrawingService.swift) for the surrounding contracts and distinct acceptance gates.
