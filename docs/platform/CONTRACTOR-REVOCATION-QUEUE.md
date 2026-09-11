# Native Contractor-link revocation handoff

## Root integration verified — 11 September 2026

The complete native integration is committed at **`6e751fa`**. Xcode's Staging build and the 19:25 UK test run succeeded: **226 passed, zero failed, five existing skips** (231 total). All three previously local-only revoke paths now call the shared request entry point; the main Links screen also offers it. Root auth/foreground/deferred-revision hooks reconcile durable confirmations, pending states are shown, and the send manager blocks repeat sharing/reminders while a current-scope revocation is pending. `SLMagicLink.revoke()` was removed to prevent local-only reuse.

Actual simulator navigation verified Projects → Contractor links → Choose a project, Add snag, and the guest sharing gate. Historical local revocation flags remain qualified; deployed authenticated revocation, complete large-text/VoiceOver and full account-scoped data isolation are still open. See `READINESS-RESUMPTION-2026-09-11.md` for the final result paths and actual captures.

## Earlier bounded agent handback

The remaining handback text records its narrower state before root integration. Its “uncommitted” and “awaiting app-target” descriptions below are historical, superseded by the checkpoint above.

Prepared 2026-09-11 by the portal-delegation agent for the root build session. This is the bounded native queue and UI-entry-point work, not a claim that end-to-end revocation or go-live is complete.

## Source and status

- Repository: `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink`.
- Branch: `feature/unified-platform`; HEAD at this handback: `a684663d07aec774638897a78811fa4ea0478f2f`.
- Owned source: `Snaglist/Services/MagicLinkSyncService.swift` (uncommitted).
- Owned new tests: `SnaglistTests/ContractorRevocationQueueTests.swift` (uncommitted, existing filesystem-synchronised test group).
- No PBX edits, other native source edits, API-contract changes, deployment, real requests, email, customer data or real Keychain writes were made by this subtask. Root owns AuthManager, Root/UI hooks and final Xcode verification.
- Source SHA-256 at handback: `707246b172aa4787dd168e8413a966b25739cc414fd4939d6e5793c32beb0942`.
- Test SHA-256: `3e17647a3816c9014acef6a01c42d7aa1427ee902d54be8e4cb478cb68f6dcf7`.

The queue and batch coordinator are **implemented and tested in an isolated local Swift runner**. The service's SwiftData/Keychain adapters and actual iOS UI integration still require the root app-target verification. Nothing here has been verified in deployed production.

## Defect and actual contract

The old service stored an unowned `[String]` of Contractor-link tokens in `UserDefaults`, under `com.snaglist.magiclink.revocationQueue`. A reconnect could send every token using whichever account happened to be signed in. An asynchronous acknowledgement could remove original work after an account switch.

Separately, root found the service had no production UI callers: the three revoke/discard/delete paths called `SLMagicLink.revoke()`, which only sets `revokedAt`. The affected paths are `PendingLinksListView.revokeLink`, `MagicLinkGeneratorView`'s send-exit discard action, and `MagicLinkHistoryView.onDelete`. Their previous local flag/toast did not prove server revocation. Root is replacing those callers.

The actual native contract remains `APIClient+MagicLinkSync.revokeMagicLink(token:)`: authenticated `POST /api/v1/magic-links/:token/revoke`, no body. In the current Swift backend, `MagicLinkController.revokeByToken` checks the authenticated creator/access policy; its legacy and v2 grant compatibility paths accept repeat revocation without reactivating the link. Expired/already revoked links remain revocable. This is source evidence; the present deployed environment still needs the planned real staging journey.

The local operation UUID is only durable queue identity. It is not an invented server idempotency header or a new API route.

## Implemented behaviour

1. Before sending, persist the original link UUID/token, backend-account UUID, environment, exact API origin, contract version, operation UUID and creation time in a private Keychain envelope. The queue never persists the auth bearer token.
2. Use the existing `AppConfiguration.keychainService` and a separate `contractor_link_revocations_v1` item, with `AfterFirstUnlockThisDeviceOnly` and no Keychain synchronisation. Add/update are used without deleting the existing item first. Read, decode, schema and write/readback failures stop network work and preserve prior bytes.
3. Copy the old UserDefaults payload into an ownerless private quarantine. Do not infer ownership, replay its tokens, delete the source value or include it in customer-facing output. Identical payloads are not copied repeatedly; unknown legacy formats are preserved as opaque bytes.
4. Capture immutable account/origin scope, `APIClient.sessionGeneration`, `AuthManager.sessionRevision` and a local binding generation for active work. Check before send, after success/error, before acknowledgement and before each next batch row. A→B→A does not revive an old lease.
5. Retain failed or uncertain operations for the original scope. Reconnect filters by all original scope fields. Do not silently redirect old work if a later app changes its API origin.
6. Suppress overlapping sends of the same operation. Reload persisted state after awaiting so acknowledgement cannot overwrite another entry added meanwhile.
7. Atomically move an acknowledged request into a durable confirmation receipt. Do not throw away the original identity/token before local reconciliation.
8. Reconcile synchronously into the current root-supplied `ModelContext`: require current account/environment/origin, fetch the exact link UUID and token, save `revokedAt`, then consume that receipt. Missing/deleted links, mismatched scope, failed local save or failed receipt consumption preserve the receipt. A failed local save restores the prior in-memory `revokedAt` value.
9. Publish only a `revocationRevision` counter for root reconciliation; no private tokens or token-bearing URLs are logged by this queue.
10. Review/demo mode is guarded from the real queue and network entry points.

## Root integration contract

Call `MagicLinkSyncService.shared.authenticationChanged()` synchronously after auth adoption/clearing and persisted-session restoration. It invalidates queue and UI-batch bindings, then schedules a scoped retry. It must never clear another account's entries or confirmations.

The root should observe `revocationRevision` and call `reconcileRevocations(in:)` with its **current** context. Defer the subscriber to the next main-loop turn (`receive(on: RunLoop.main)`) and guard against re-entrant reconciliation: storage is written before publication, but consuming a receipt publishes another revision and synchronous `@Published` delivery can recursively enter the consumer. Also reconcile on root/auth-context setup, so an existing receipt is handled after process restart even if no new network acknowledgement arrives. Catch/save failures honestly; an unreconciled receipt remains available. Call `retryPendingSyncs()` on normal app foreground/return as well as reconnect.

For each of the three UI paths, call this directly from the synchronous action:

```swift
MagicLinkSyncService.shared.requestRevocations(links, in: modelContext) { message, success in
    // Present message. success is true only when all links are confirmed and saved.
}
```

Do not place that call inside a new Task: the entry point must snapshot the selected link UUIDs/tokens and current identity **before** asynchronous work starts. It returns its own `Task<Void, Never>` if the UI needs cancellation. It captures no SwiftData model across network suspension. Context access and completion are suppressed if its lease changes.

The shared coordinator distinguishes:

- Server-confirmed and locally saved: success=true, “Contractor link revoked.”
- Offline or unconfirmed write with durable pending work: success=false; the Contractor link may remain accessible until confirmation.
- Server-confirmed but local record missing/save pending: success=false; server confirmation and pending local update are stated separately.
- Auth/storage failure without confirmed or durable pending work: success=false with safe retry guidance.
- Partial batches: retain individual outcomes and report counts; stop before the next row or any UI/model callback after identity change.

`hasPendingRevocation(for:)` is available for row state. `revokeMagicLink(_:)` now returns `.pending` / `.confirmed`, but UI callers should prefer the shared synchronous batch entry point to avoid duplicating its lease checks.

## Verification

- Strict Swift 6 queue/coordinator/Keychain-adapter compile: passed.
- Swift 5 language mode with default MainActor isolation (matching the app's configuration): typecheck passed.
- Direct Swift Testing execution: **23 tests in 2 suites, 40 parameterized cases, 0 failures**, final run 0.021 s. Tests use synthetic values, in-memory persistence and injected transport; no real network or Keychain writes.
- Tests exercise owner/environment/origin filtering; A→B→A at API/auth/binding levels; signed-out rejection; immutable pre-Task capture; stale completion/batch suppression; unknown legacy retention; durable-write verification; corrupt storage; lost replies and restart; concurrent retry suppression; cancellation; atomic confirmation receipts; failed/missing local consumer; receipt consumption failures; and truthful full/partial outcome copy.
- `git diff --check`: passed at handback.
- The initial Swift Package runner could not execute its nested manifest sandbox (`sandbox_apply: Operation not permitted`). No sandbox was disabled. The same extracted source and copied test file were instead compiled normally with `swiftc` and run through the installed Swift Testing framework entry point in the existing sandbox.

Evidence:

- `outputs/readiness/contractor-revocation-queue-tests-direct.log` — successful final tests.
- `outputs/readiness/contractor-revocation-queue-tests-compile.log` — final test compile, no diagnostics.
- `outputs/readiness/contractor-revocation-queue-module.log` — strict Swift 6 module compile, no diagnostics.
- `outputs/readiness/contractor-revocation-queue-app-mode-typecheck.log` — app-like typecheck, no diagnostics.
- `work/readiness/revocation-tests/` — exact extracted queue/coordinator source, copied tests, installed-framework runner and local compiler outputs. This is a local verification fixture, not another app implementation.

## Remaining limits and acceptance

- Root must build/test the actual iOS target and exercise all three wired UI paths. The extracted runner does not verify SwiftData query generation, actual Keychain entitlements/protection, simulator UI or server transport.
- Real staging must show that manual revocation and delayed/reconnect revocation actually deny Contractor-link reads/writes/uploads, while another account's link is unaffected. No production experiment was made.
- Historical local `revokedAt` values still cannot establish previous server revocation. Do not infer never-uploaded from `backendSyncStatus == pending` or unsent UI state: partial uploads and lost replies are possible. No automatic reassignment or speculative migration from these values is included.
- A new-session retry skips an old request still in flight. If the old reply is then rejected after A→B→A, retained work needs the next eligible retry (foreground/reconnect/manual); there is no timer. This is safe retention, not evidence that the request completed.
- Private queue tokens and receipts are device-only; they are not exported into the public recovery/Drive documentation or synced to other devices. The old UserDefaults source is intentionally retained. Future secure migration/recovery must preserve this distinction.
- The queue and receipt protocol does not solve general SwiftData account partitioning. Root retains that separate launch gate and must supply the current context for reconciliation.
