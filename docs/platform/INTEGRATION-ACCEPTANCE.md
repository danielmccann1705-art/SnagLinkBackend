# Seamless Snaglist app and portal integration — acceptance contract

Updated 11 September 2026. Owner requirement: the iOS app and manager portal must operate as one product. This document implements the v1.1 brief's G1 and sync/migration gates; it does not replace that brief. **Full integration is not implemented or verified yet.** Local prerequisites are identified separately from end-to-end acceptance.

## What the user should experience

Log work on the phone, including offline. Open the same account and project in the portal and see the same references, locations, assignments, photos and evidence. A second authorised manager can coordinate that project without receiving personal projects. Contractors use a no-account Contractor link, submit a repair with evidence, and wait for a manager to accept it. That accepted result must return to the phone and appear identically in the issued report. The user must always know whether a change is on this device, waiting to send, awaiting review, conflicted or confirmed by the server.

## Authority and invariants

1. The canonical server graph is authoritative for shared projects, permissions, published revisions and accepted closure. SwiftData is an account/environment-scoped local replica plus local-only work and an immutable outbox. This is the target architecture; the current app is still primarily local.
2. A report is an immutable issued snapshot with its revision/evidence manifest. It is not the mutable master project or a shortcut for bidirectional sync.
3. A workspace membership, project grant and current user identity authorise access. Matching an email, knowing a project UUID or owning an old link is insufficient. No browser-only role rule may replace a server check.
4. IDs and reference aliases survive import, retries, devices and reports. Do not generate an unrelated replacement project UUID when an association is missing.
5. Every mutation has a stable operation ID, exact payload and expected entity revision. An uncertain outcome is reconciled or replayed under that same contract. Generic HTTP retries must not create a second action.
6. An offline edit cannot overwrite an accepted decision or revive an archived snag. A conflict retains the user's draft and clearly explains the latest server state.
7. Original/annotated/processed evidence have explicit relationships, checksums and access rules. Upload acknowledgement is not attachment acknowledgement. Missing files and interrupted uploads must be visible and recoverable.
8. Accepted closure requires a server-recorded manager decision about the current submitted attempt. Submitted, Awaiting review and Closed remain different. Historic native status aliases may be decoded but never collapse submission into acceptance.
9. Logout/account switch invalidates outstanding local callbacks, isolates data/media/preferences/queues, and prevents departed account work from being adopted in the new account. Server writes need their own ownership/version checks; cancellation is not rollback.
10. Removing access stops reads, writes and private media on both surfaces. Any remaining offline copy needs the specified access-removal treatment. Do not claim revocation from a portal button alone.

## Required ordinary journey

Use one coherent synthetic project, for example Willow Mews, Plot 3; door latch, shower seal and damaged plaster snags. Preserve the seed and operation IDs in a redacted evidence manifest. All photos must be synthetic or explicitly authorised test assets.

1. **Manager A / native:** ordinary capture on a clean staging install creates a project and snags, each with photos, description, plot/floor/room or location, contractor/trade, priority and stable reference. Include an offline capture and annotation.
2. **Sync/import:** reconnect; commit immutable writes and attachments, then explicitly transfer/import the intended project to the company. Keep a recoverable device backup and local-only projects. No SQL-created project may substitute for this step.
3. **Manager B / portal:** a genuinely distinct backend user verifies and accepts an invitation; membership and scoped Manager grant are visible. B opens the exact project and checks all fields/evidence. B edits assignment and a location while A is offline.
4. **Delegation:** B selects the intended snags and creates a PIN-protected, expiring Contractor link from ordinary UI. Scope and evidence are shown before activation. The actual recipient sees only authorised work.
5. **Contractor / mobile browser:** open the link without an account, enter PIN, view before evidence, provide required after evidence/notes and submit. Repeating an interrupted submission must not create another attempt.
6. **Review:** B sees the current attempt, requests further work on one snag, receives a repeat submission, and accepts it. Another snag remains Awaiting review. No contractor action closes work directly.
7. **Return to iOS:** A reconnects. The newer assignment/location, every submission and manager decision, current state and private evidence arrive. A's stale offline status edit produces a visible retained conflict, not a rollback of B's acceptance.
8. **Fresh device:** A signs in on a separate clean installation and reconstructs the complete project, including drawings/pins and history. Compare IDs, relationships, content hashes and server revisions; do not compare only counts or thumbnails.
9. **Report:** issue and download the report from a defined revision. Compare native, portal, contractor and report states side by side; record exactly which evidence/reviews it includes.
10. **Revocation and archive:** reassign/revoke the old grant and archive one snag; old links lose relevant access immediately. Restore through authorised UI without losing retained history, and confirm restoration does not silently resurrect an old grant.

## Failure and continuity matrix

All rows below are **open as integrated staging acceptance** unless explicitly qualified. Unit tests prove only the named local mechanism.

| Scenario | Expected result / evidence |
| --- | --- |
| Same person uses two explicitly linked sign-in methods on app/web | Same backend UUID and appropriate personal/company access; no email-based merging. Real Google/Apple/Microsoft/email round trips required. |
| A → B → A with requests in flight | No A data/tier/draft appears in B. Prepared/replied authenticated API requests are locally generation-checked; whole store/media/purchase isolation remains open. |
| Legacy device upgrade | Original store/media backed up with checksum inventory; resume-safe import preserves IDs, relationships and unowned records for explicit resolution. No silent adoption by next login. |
| No connectivity at capture | Save complete local intent and original media; visible waiting state; reconnect resumes exactly once with stable IDs. |
| Connection lost after server commits | Reconcile by operation ID; no duplicate snag, photo, grant, submission or decision. Native generic write retries are removed; canonical outbox integration remains open. |
| Crash during image upload / attach | Resumable upload intent, validated bytes, attachment receipt, cleanup of abandoned unreferenced objects; preserve originals and honest progress. |
| Concurrent edits | Expected revision checked server-side, retain conflicting draft, refresh current state, resolve deliberately. Test native ↔ portal and portal ↔ portal. |
| Server refusal / uncertain review | No false local Closed state. Personal native review has injected-transport/persistence regression tests; canonical native v2 review and real staging remain open. |
| Old queued approval | Retain payload/history for fresh review; never submit an ownerless, revisionless decision as current-user intent. Local replay guard implemented. Repair UI remains open. |
| Slow list refresh while editing | Keep selected snag, filters, sort, scroll and draft; do not overwrite local input with an arriving list response. |
| Page beyond 50/100 results | No missing records/evidence/reviews; stable snapshot boundary and bounded deltas; report includes complete selected scope. |
| Expired sync cursor | Safe rebootstrap without losing unsent drafts, tombstones or local-only projects. |
| Project membership removed while open | Refresh and server writes fail safely; navigation explains lost access, private media unavailable, no cached sharing options imply authority. |
| Contractor reassigned or snag archived | Old grant immediately loses affected reads/writes/uploads/photos; no widening to whole project from an empty selected-ID list. |
| Repeat submission and send back | Immutable attempts, reasons and evidence visible; decision always refers to the reviewed attempt. |
| Two managers decide concurrently | One authoritative revision wins; other manager sees conflict with latest result, keeps note; no duplicate notifications or stale close. |
| Deletion/account closure | In-app initiation, reauthentication, identity revocation and defined shared-data retention/transfer; test both web/native access afterwards. |
| Purchases and seats across devices | Server-verified rightful entitlement after purchase/restore/login; no global cached Pro transfer; contractors consume no company seat. |
| Provider/email outage | Clear recoverable failure, no false success or invented account, durable delivery retries and correct authorised recipient. |
| Large project and accessibility | 5,000-snag measurements, bounded memory/request sizes, keyboard/zoom/responsive web, native large text and VoiceOver; genuine staging captures. |

## Evidence package that closes the gate

- Exact native, portal and backend commits; deployment image digest, schema ledger and environment origins. Preserve public production vs current branch distinctions.
- Continuous workflow recording plus actual native/browser/report captures. D1/D2 comparison must include long/empty/error/conflict states and measured viewport/text settings.
- Redacted trace of operations/revisions: project + snag stable IDs, attachment acknowledgements/checksums, completion attempt, manager review decision, native applied cursor and issued report snapshot.
- Legacy upgrade/reopen, crash/retry, two-account and fresh-device reconstruction results. Missing data counts or an incomplete graph fail the gate.
- Role/access-negative and Contractor link expiry/revocation/PIN/media checks. No credentials, private tokens, customer data or original sensitive photo metadata in shared evidence.
- Explicit residual defects with severity and release disposition. Passing local API tests cannot waive user-visible data loss, false closure or confusing ordinary workflows.

## Execution ownership

This build session owns native safety/import/sync, the canonical contract additions they need, matching staging, and the shared acceptance loop. Portal work can proceed on delegation, state preservation and company operations against reviewed contracts. Contract or migration changes must be recorded before another session builds against them. Existing code/design is preserved and amended incrementally; no backend replacement is needed to close these gaps.

See `GO-LIVE-PLAN.md` for the dependency order and `SECURITY-PRIVACY-READINESS.md` for the source audit. The readiness checkpoint will record exactly which local tests passed; neither document claims the full journey has passed.
