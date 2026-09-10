# Platform acceptance — work in progress

G0: partial. Source archives/manifests preserved; native full build/Simulator restricted. Isolated native scheme/store migration not yet implemented.
WP-01: verified identity/session foundation locally tested. Browser transport and sign-in form built and unavailable-service state inspected. Real provider email/browser round-trip, native verified-email UI, Apple web configuration, account deletion/provider cleanup and legacy email-only recovery remain open.
WP-02: additive workspace/membership/grant/invitation schema, services and project capability endpoints implemented. Ten new database integration tests pass. All legacy/media/job paths and lifecycle/transfer coverage remain open; not rollout-ready.
WP-03: project/stable-snag creation, revision-aware edits, hash-bound retry receipts, reference allocation, publication, archive/restore and atomic change rows implemented; the expanded canonical suite passes 16 local API tests, now including immutable register snapshots and per-project deltas. Full graph parity, directories/media, migration, global grant discovery and native outbox remain open.
WP-04 through WP-11: existing recovery/design work retained; complete canonical sync, unified workflow, private media, native migration, integrated register/workbench, jobs, reports, test billing and release evidence remain underway or absent as specified in the brief.
D1: core samples retained and inspected previously, plus real sign-in entry inspected. Continuous recording and fresh PDF comparison outstanding.
G1/G2/G3/D2/G4/G5: not passed. No simulated or local-only result substitutes for their real environment acceptance.

## Current verification artifacts

Local runner output: `outputs/app-store-prep/backend-tests/platform-accounts-workspaces.{json,log}` (58 pass); `platform-legacy-access.{json,log}` (44 pass); `platform-mutation-compile.{json,log}` (13 pass); `platform-canonical-mutations.{json,log}` (10 pass). These runs overlap; do not add them into a distinct-test total. All use disposable local PostgreSQL. Provider delivery, real staging and device checks are not implied.

The current source-file hash inventory is `backend-canonical-source-manifest.json`. The source remains uncommitted on `feature/unified-platform`; preserved recovery archives remain separate. Native blocker: `ios-baseline-build.log`. Actual browser connection-error capture: `account-unavailable-desktop.png`; it is not a successful sign-in proof.

Latest expanded run: `platform-full-backend-final.{json,log}` — 188 tests, zero failures/skips. `platform-invitation-preview.{json,log}` — 11 workspace tests after adding recipient-verified preview, including one new case. Portal build and all 11 checks pass. The later invitation preview is covered by its scoped run, not retroactively by the 188-test run.

Recording/native tools were retried: macOS Screenshot controls returned computer-use timeout; Xcode was located with the Snaglist project open but its accessibility/screenshot request also timed out. These are still unverified external capabilities, not passed D1/device evidence.
