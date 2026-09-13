# Snaglist — remaining work and economical completion sequence

13 September 2026. Assessment based on current code and observed acceptance, not older product descriptions.

**The app and portal are not ready for submission. This remains several substantial implementation and acceptance passes, rather than final polish or one last test run.** No reliable completion percentage, hours-to-release or credit forecast is established. The biggest uncertainty is the first complete preserved project moving through both surfaces and reconstructing on a fresh device. Estimate again immediately after that passes.

| Remaining area | Size / status | Completion condition |
| --- | --- | --- |
| Safe import and two-way sync (R1, part R0/R6) | **Largest implementation gap.** Account isolation/recovery/source preparation and backend original transfer have tested foundations. Native file upload, typed canonical publication, full readback and outbox/bootstrap/deltas remain unfinished. | Existing and newly captured project, all IDs/photos/drawings/pins/history, portal and fresh-device parity; interruption/retry, conflicts, deletion and account switching preserve work. |
| Account lifecycle (R2) | **Medium implementation and external verification.** Real Google web staging login passed; native exchange and the complete Apple/Google/Microsoft/email lifecycle and production registration remain open. | Actual provider round trips, recovery/linking/revocation/deletion and native/web same-account behaviour without unsafe email merging. |
| Media, reports and operations (R6/R0) | **Substantial integration.** New staging photo API plus portal read/enlarge passed; full native transfer, isolated drawing processing, complete reports and durable jobs remain open. | Private originals and processed evidence survive reconstruction; plan pages/pins agree; reports complete; retry/delivery and current-recipient behaviour verified. |
| Team/admin and billing (R3/R5/R7) | **Substantial remaining implementation/acceptance.** Existing screens and server foundations do not establish finished team administration or verified subscriptions. | Membership/roles/project access/ownership, admin destinations, seat boundaries and sandbox purchases/restoration work on both surfaces; current Pro pricing preserved. |
| Shared workflow and usability (R4/R5) | **Required integration/design acceptance.** Not passed end to end. | Native capture → distinct second manager → scoped PIN Contractor link → evidence/send-back/resubmission → manager acceptance → app/fresh-device/report, plus errors/permissions/conflicts/responsive/keyboard/zoom/large text. |
| Device and release candidate (R8) | **Final acceptance and founder input.** Existing archive is obsolete. | Real upgrade without data loss, camera/photos/deletion/drawings/exports/purchase restore; production configuration; new exact-source archive, TestFlight, reviewer access/metadata/privacy and explicit submission decision. |

## Recommended order to conserve usage

1. Complete **one project across app, portal and fresh device**, including its files and a drawing/pin. Reuse the existing implementation and evidence. Work serially on this dependency; avoid further broad audits, optional features or parallel design expansion.
2. Complete the **second-manager and contractor close-out journey**, fixing only the remaining required dependencies in access, media, reports and sync.
3. Finish the agreed provider, team/admin and commerce gaps and D2 acceptance against the same staging version.
4. Run founder physical-device acceptance, resolve blocking findings, then create the final archive and submission handover.

Use the existing R0–R8 plan for detailed gates; do not weaken account isolation, migration, permissions or release acceptance to save credits. Reuse passing tests for unchanged source, with targeted regression tests for changes. Record one concise checkpoint per completed result and refresh Drive then, rather than repeatedly rewriting historical reports.

## Current saved progress

Native `42b1eb1`: staging417 unique tests passed/five existing skips (561 passing executions). Ordinary scheme and new screens still require acceptance. Backend `f3686af`:46 focused local tests passed; not deployed. Staging backup/restore:61 tables matched. Older90748aa Linux image/runtime passed; not deployed and not the latest backend. Projection draft is preserved but uncompiled/unintegrated. Native file-transfer implementation has not started.

Two previous inputs remain open: native Google sign-in in the preserved iPhone17Pro simulator and browser extension file-access setup for the upload picker. Physical-device/founder TestFlight input will be needed after the integration checkpoint, not before it is testable. No new credential/billing approval is required now.

Parallel agents reported the account usage limit. Their drafts and exact test evidence are saved. Nothing was merged, deployed to production, purchased, uploaded to App Store Connect or submitted in this checkpoint.
