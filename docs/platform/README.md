# Snaglist — app build and engineering

## Current checkpoint — native Google implementation, 11 September 2026

Native **f9fb682** (`feature/unified-platform`) now implements Google sign-in and explicit same-account connection with the official SDK. The final staging app builds and runs in Xcode 26.2; **148 tests pass, 10 historical network-dependent tests are skipped, zero fail**, including all eight new Google-flow tests. Actual simulator captures show the shared Plex/Marker/Ink/Stone sign-in form, retained email draft, availability failure/retry and dark appearance.

**Live native Google is still unverified:** the staging app could not confirm the matching service configuration. The Vapor implementation and prior real Google web verification use an isolated local development environment. Neither is a deployed native-provider or production pass. The GUI build supersedes the earlier blanket native-build blocker; command-line sandbox limitations remain. No Xcode restart is currently needed.

Read [NATIVE-GOOGLE-SIGN-IN.md](https://drive.google.com/file/d/1IJ8jV4RHapOacGS7wZp-_-f8682POEut/view) and the [native evidence bundle](https://drive.google.com/file/d/1WdWN9qTUug-hJlfoFTmfIAh8sZuegL8w/view) for exact source, files, tests, configuration and limitations. Largest-text header reflow is captured; lower-form scrolling and full VoiceOver are unverified. Native Projects/Settings still have older styling/copy and unsupported real-time collaboration claims to resolve.

**Next:** manager Add/share/link workflows; account-partitioned native stores/media/queues and recoverable import/outbox/pull; matching Linux/private-R2 staging and real native Google; remaining company branding/seats/test billing/workbench; ordinary native/two-manager/contractor G1 and complete D1/D2. Full native sync, team billing and the platform are not complete. No merge, push, production cutover, live prices or App Store release occurred. Earlier entries below describe their dated source checkpoints.

## Earlier checkpoint — Google web sign-in, 11 September 2026

Backend **1abdb42** (`feature/unified-platform`) and portal **eafe6a0** (`feature/unified-portal`) implement Google authentication and explicit same-account linking. **Actual Google browser sign-in is verified in the isolated development environment:** linking, chooser cancellation/retry, logout and returning through Google retain the existing synthetic account and company Owner access. A read-only database check confirms one Google identity alongside the original email identity and unchanged active ownership. This is not production or native Google acceptance.

Read [GOOGLE-SIGN-IN-VERIFICATION.md](https://drive.google.com/file/d/1zdtUA4jIr4l0Wj05RHm6tVDnVx_h2Mmr/view) for current source/file paths, configuration, migration/rollback constraints, endpoint map, actual captures and the [evidence bundle](https://drive.google.com/file/d/1XI461SgKAnUQWspY7-Pyhd95h8UOckbg/view). The new Google cookie exposed a confirmed Vapor parsing defect; the fix preserves secure session/PIN cookies and independent sign-in tabs. The official provider button now resizes without changing its nonce. Company and project context remain in place while account settings is open.

**Evidence:** 59 identity/current-and-legacy-Contractor cases pass after the cookie fix; a separate **25-case final run passes at 1abdb42**, including two simultaneous sign-in challenges. These are source-specific runs on a retained isolated Neon database, not an exact-final 59-case suite or fresh production database. Portal contract/types/build and **50 tests pass at eafe6a0**. Actual 320/390/768px constrained-frame checks found and fixed button overflow; final mobile captures are 390px. No physical-device, exact full-window dimension, 200% zoom or complete D2 pass is claimed.

**Still open:** native Google SDK/UI and real native-provider verification; native account-partitioned sync/import/outbox; manager Add/share/bulk/link management; company profile/branding/seats/test billing; plans/reports/durable jobs; private R2/Linux staging; G1 and remaining D1/D2 evidence. The 11 September recheck reports Xcode 26.2 but a disconnected CoreSimulator service, so there is no fresh native build. Local Google clients and External/Testing consent are configured; production clients/publication remain absent. Older-session Google linking currently asks the user to save work and sign back in; smoother reauthentication/disconnect recovery remain work to finish.

The v1.1 brief was fetched again and its revision note, section 12 design gates, working product defaults and handoff instructions were checked. No merge, push, live pricing, production deployment or App Store release occurred. Preserve the existing native reskin, branches and unrelated work. The following checkpoint text is dated history.

## Earlier checkpoint — Company administration, 11 September 2026

Backend **25065df** (`feature/unified-platform`) and portal **222866d** (`feature/unified-portal`) add Owner/Admin company administration to the existing connected Contractor link journey. Members, verified-email identification, invitations, company roles/removal/ownership controls, explicit project permissions and a scoped activity history use the real API and existing central permissions. Personal projects remain separate. No live Team pricing, seats or billing is implied.

Read [COMPANY-ADMINISTRATION.md](https://drive.google.com/file/d/1vDRg162rYTTKVdlS6Y9EaDZrsAlBbGb6/view?usp=drivesdk) for the capability table, endpoint/file map, conflict and retry rules, source fingerprints, actual browser captures and remaining dependencies. It distinguishes browser-exercised actions from server-tested controls. Synthetic browser use verified company role changes, invitation creation/copy/revocation, retained drafts and a Manager grant for a second colleague. No external email or production record was used.

**Evidence:** 66 backend cases passed at a783ed9; after the verified-email refinement, 16 relevant cases passed at exact final 25065df. These are separate runs against a retained isolated synthetic Neon test database, not a newly created database or an exact-final 66-case pass. Portal contract/types/build and **43 tests pass** at 222866d. Final browser checks corrected dialog step focus, nested-photo Escape and cramped tablet email layout. Responsive captures are labelled iframe inspections; no new physical-device, zoom, numerical iframe-overflow or full D2 pass is claimed.

**Still open:** Google login on iOS/web; full native account-partitioned sync/import/outbox; manager Add/share/link management; company branding/seats/test billing; drawings/reports/durable jobs; private R2/Linux staging; the native/two-manager G1 journey; D1 workflow recording/native-report comparison and real staging D2. A dedicated Google Cloud project and external Testing consent configuration exist; no OAuth client or working Google login is verified at this checkpoint. Xcode/Simulator connection failure still prevents a fresh native build; the earlier 7 September report is historical. No merge, push, production deployment or App Store release occurred.

The approved v1.1 brief and supplied brand assets remain controlling. The following entries are dated history, not additional claims of current completion.

## Earlier checkpoint — Contractor links, 11 September 2026

Backend **fb42916** on `feature/unified-platform` and portal **de215b1** on `feature/unified-portal` now connect no-account Contractor link evidence submission to the manager's canonical review workspace. Actual browser use verified PIN entry, private after-photo upload, retained drafts, awaiting review, manager acceptance and accepted closure after reload. A scoped database read confirmed one accepted grant-attributed attempt, one evidence association and one real-user acceptance; notification rows remain queued, not delivered.

The core backend regression passed **234 tests, zero failures/skips**. After the final supplied-v2 identity, attachment-control and cache refinements, **8 focused grant tests passed again** at the exact final source fingerprint. Portal contract/types/build and **31 tests pass**. Final responsive checks cover 320/390/768/1024px iframe widths without horizontal overflow; they are not physical-device or browser-zoom acceptance. The wordmark is copied unchanged from the same supplied v2 asset used by the portal, with shared Plex/Marker/Ink/Stone treatment.

Read [CONTRACTOR-GRANTS.md](https://drive.google.com/file/d/13n1i2S_i9UtMp3QpADAowY_-0ypR6xi0/view?usp=drivesdk) for contracts, scope, PIN/media/actor security and configuration, and [CONTRACTOR-LINK-REVIEW.md](https://drive.google.com/file/d/1rzo58sVN1MfFZ72OjKPsPzV9yz5xDOGa/view?usp=drivesdk) for source-specific tests, actual captures, reproducibility and limitations. Earlier [connected manager review evidence](https://drive.google.com/file/d/127OOiTiWcKU904asY9rjpOB8-3c5Bu1O/view) remains relevant at its recorded revision.

This is local application code and an isolated synthetic Neon review environment, not the recovered Cloudflare staging deployment. No production records, external email, prices or release state changed. **Native full build/capture/sync, manager Add/share/link management, full graph/drawings, durable jobs, private R2/Linux staging, D1 recording/native-report comparison, G1 and D2 remain open.** Google login on iOS/web and comprehensive Company Owner/Admin administration are explicitly required and not yet complete; preserve [that scope amendment](https://drive.google.com/file/d/1uM-7BkQd8ID5btihXfoL9BAe1uE1FvUg/view). No whole work package or release gate is complete.

## Historical checkpoints and retained source detail

The following records describe their dated revisions. Present acceptance is stated above and in the linked current verification report.

## Earlier checkpoint — manager review, 11 September 2026

Backend application `7b4c8cd` now passes **226 tests, zero failures/skips**, on a fresh isolated Neon PostgreSQL 16 database; all eight workflow cases also pass independently. Portal `455c3e1` builds and passes **31 tests**. Actual browser review verified private before/after evidence, historical attempts, retained notes, accepted closure after reload and stale competing-decision rejection. A discovered no-op conflict button was replaced with a clear explanation and readable retained note. Responsive iframe widths 320/390/768/1024 showed no horizontal overflow; this is not physical-device or zoom acceptance.

The new synthetic-only Neon Free test project is separate from recovered staging. A restricted, endpoint-pinned runner leaves the original local-only guards unchanged. Interactive email is intercepted locally; no external message or production deployment occurred. Native full-build, canonical Contractor links, full sync, D1 recording/native PDF, real G1/D2 and remaining work packages stay open.

Dan also explicitly added Google sign-in on iOS/web and comprehensive company administration for Team plans. See [Google sign-in and team administration scope](https://drive.google.com/file/d/1uM-7BkQd8ID5btihXfoL9BAe1uE1FvUg/view) and the [connected review verification report](https://drive.google.com/file/d/127OOiTiWcKU904asY9rjpOB8-3c5Bu1O/view) for evidence, runtime boundaries and next dependencies. Earlier database-unverified statements below describe the 10 September checkpoint and are superseded by this executed verification; no whole package or release gate is complete.

Historical dated observations and source detail follow. Use the current checkpoint above for present verification status.

## Historical checkpoint — private media and review, 10 September 2026

Backend `7b4c8cd` (workflow candidate; private-media base `6d742bf`); portal `f763ae2` (review candidate; private-photo base `1e8e387`); native `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`. Local branches only; no deployment/release.

[Actual private-photo browser capture](https://drive.google.com/file/d/1AWSM8c8w2h46J0Axi2inSHQFzL08vq6X/view).

**Verified locally:** private original/processed media, authenticated gateway, revisioned capture attachments, real portal photo upload/thumbnail/enlarge/reload. Backend full suite 218 pass before the last register-preview addition, then seven relevant cases pass; portal build and 31 tests now pass.

**Implemented but unverified in the database/browser:** canonical attempts, decisions, evidence consumption, reasoned waiver/internal fix/reopen, queued notifications, completion-history snapshots, transaction-grouped deltas and the connected review workspace. All backend application/test code compiles. The eight new workflow tests failed at database setup, so none is a workflow pass. The new review workspace still needs actual browser rendering/interaction inspection; the earlier connected-photo capture is separate evidence.

**Current blocker:** OrbStack/Docker's task database stopped responding and the OrbStack app shows setup requiring Dan's acceptance of its terms/privacy. A separate official PostgreSQL 16.15 source build succeeded, but the sandbox denied shared-memory initialisation. Neither path currently supplies a working test database. Existing databases/other projects were not reset. Native build still has its separate package-sandbox/CoreSimulator block.

See [WORKFLOW.md](https://drive.google.com/file/d/1x8NH7hxbBjoeyv65CUVfEuE-_iytKfZB/view) for architecture, exact file/symbol references, test labels and resumption instructions; [PRIVATE-MEDIA.md](https://drive.google.com/file/d/1h3md2ZhJ4rlrJdakMHsKEwTD0o36riEP/view) for upload/storage boundaries. D1 recording/fresh native PDF, real D2 and G1–G5 remain open. Earlier dated sections are historical checkpoints, not claims that later code passed their tests.


## Active platform build — source checkpoint, 10 September 2026

The current local source is now preserved in review branches: backend `7ddbc3a81cda8e7af1c7e50c44d40c443b3a8a56`, native `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`, portal `3c19fae`. The supplied brand, approved reskin/icon and existing portal design samples are retained. Browser identity/session foundations, verified invitations and memberships, central project permissions, revisioned canonical writes, register snapshots/deltas, workspace directories/assignment history and exact calendar/cost values now have local test evidence.

- [PLATFORM-BASELINE.md — source checkpoints and build evidence](https://drive.google.com/file/d/1J7NAfJZXQmCBJpBZePj41gw1KJX-_7gw/view)
- [PLATFORM-DECISIONS.md — identity, permissions, sync, deletion and data rules](https://drive.google.com/file/d/1uM9peBZdKKjovZ9i8DGaEY3LPDHIjon3/view)
- [PLATFORM-ACCEPTANCE.md — all work packages, actual results and open gates](https://drive.google.com/file/d/15pVs9OrdZ9yX1HkNY2HLAHIhHwRum3TM/view)
- [IOS-STAGING.md — isolated app configuration and remaining device checks](https://drive.google.com/file/d/1vGZH3lODM5b8mzHUfXS1j4Jg5NQfTMav/view)

**Verified locally:** the latest full backend run passes 210 cases; the subsequent strict email-delivery change passes 12 scoped identity cases. Earlier fresh-schema evidence passes 199. The connected portal checkpoint builds and passes 20 checks; later minor corrections are under final build verification. Actual local Chrome sign-in, project register, draft retention/save and two-tab conflict comparison/re-save have been exercised with synthetic API-created records. Native routing/source checks pass; the full native build remains blocked before application compilation by package sandbox/CoreSimulator access. None of this claims production, external provider delivery, two genuine internal identities or the native G1 journey.

**Still open:** complete graph/media/workflow, device import/outbox and account isolation, connected manager workbench, D1 continuous recording/fresh native PDF, D2 real staging and G1–G5. No whole package is marked complete from partial evidence. Production cutover, live billing, merge and App Store submission have not occurred. Earlier sections below remain dated history and are superseded only where this update provides newer source evidence. The old design source pack is not the latest full platform source.

## Portal design candidate — 10 September 2026

The v1.1 design amendment is being implemented in a separate portal repository, branch `feature/unified-portal`, commit `25bbaecd3ac278b141f275e60220cdfcd0100c5a`. The current register/detail, evidence review and contractor phone samples use the approved brand assets and synthetic construction data. Actual file-picker, retained-draft, resubmission, acceptance/history, responsive and keyboard checks are recorded in the review log.

- [PORTAL-DESIGN.md — source mapping, tokens and interaction system](https://drive.google.com/file/d/1TGUFs2FGuodQ46uZdsc7Gf_R6bnGyxYp/view)
- [PORTAL-DESIGN-REVIEW.md — observed checks, corrections and open gates](https://drive.google.com/file/d/1DkHJIfgSkKnX2TaZCbGOglojzTwCnNJz/view)
- [Download the design evidence and source pack](https://drive.google.com/file/d/1pf5PsHwjDucOiyaNrveAAeQhKdMuoukI/view), including the capture gallery, test evidence and NEXT-SESSION.md.

**Status: D1 remains open; D2 and the real native-to-browser integration journey have not passed. This is not a released or complete portal.** Independent backend work adds guards against unverified email changes and a unit-tested permission-policy primitive; browser sessions, memberships and route-wide enforcement remain to be completed. The existing recovery/reskin work is preserved. No production data, pricing, deployment or release changed at this milestone.

## Unified platform implementation plan — revision 1.1, 10 September 2026

[Read the full development implementation plan](https://drive.google.com/file/d/1d7H-EvCfdrc0GVPGnNEXHhJVeG-SbOlL/view?usp=drivesdk) for the next Snaglist build session. It contains 24 sections and twelve dependency-ordered work packages covering canonical data and two-way iOS sync, company ownership and permissions, contractor magic links and private media, the complete browser manager workbench, drawings, reports, durable reminders, analytics, entitlements, test-mode Team billing and release acceptance.

Dan's latest direction is to build the full defined v1 in one continuous campaign, starting today and continuing as each gate passes. There is no imposed multiweek engineering delay. The first integration proof is ordinary iOS capture → a second authenticated internal user's browser → no-account contractor submission → manager acceptance → matching iOS/report evidence. Device migration, provider configuration, live billing and release readiness require their own evidence.

This is a **forward implementation specification, not completed source work or release approval**. Its recommended product defaults are explicit; proposed Team prices remain test hypotheses. The 9 September platform handover below remains the dated technical baseline until the development agent supplies newer source/build evidence. Existing brand authority, commercial budgets and production release gates remain in force.

**Revision 1.1 — portal design:** the same brief now includes a detailed section 12 covering the site-manager/small-builder avatar, existing native/brand source mapping, desktop tokens and responsive layouts, six-destination navigation, register/bulk-edit/detail/review interactions, contractor mobile UX and realistic task checks. D1 requires rendered core design samples before repeating patterns across the portal; D2 requires integrated visual/usability evidence as part of G3. These are execution checkpoints, not a new owner approval pause. WP-07/WP-08, the agent instruction and required design evidence are updated accordingly. This amendment does not claim that a portal design has already been implemented or visually validated.


## Latest source hardening and plan review — 10 September 2026

[Read the contractor-link and close-out implementation addendum](https://drive.google.com/file/d/1od4c-_HYDnfhGSE3lk78p9qZgzmVh9dt/view) for current source changes, compatibility implications and remaining release gates. [Read the development review of platform plan revision 1.1](https://drive.google.com/file/d/1775_fVSrTRYj3zrjOvwuoL6ZkL_fbtb2/view) for the recommended dependency, migration and retention amendments. [Download the scoped verification and source-hash record](https://drive.google.com/file/d/1WpYVFUBxw3mWUt7DG7U3nV215DZawJWT/view).

**Implemented and locally tested:** native-contract PIN verifier import/acknowledgement on the backend, retry-safe token revocation, prevention of direct contractor closure, serialized completion/review checks, snapshot-only approval replay protection, generic review-state PATCH protection and corrected contractor display/counts. The final runs passed **46 distinct backend tests, zero failed or skipped**. Browser JavaScript and native acknowledgement logic also passed isolated checks.

**Not deployed or device-verified:** the iOS changes have syntax/contract checks, but the app build is blocked by Xcode package-cache permissions and simulator service access. No new signed-device, staging deployment, production health or App Store result is established by this milestone. Public media, general two-way sync, durable memberships/jobs, identity recovery and purchase restoration remain open. The historical findings below are superseded only to the extent stated in the addendum.

The full 24-section incoming platform plan was reviewed; its architecture/design direction is supported with specific recommended amendments. No manager portal, new workspace architecture, mandatory-evidence policy or Team price change was implemented in this hardening slice.

## Latest platform investigation — 9 September 2026

[Read the self-contained Snaglist platform handover](https://drive.google.com/file/d/13s3JbrIVQ-Kug4P__gRZRhUZcK3JJwj_/view) before planning browser managers, company projects or team billing. It audits both working branches and dirty changes, capabilities, data ownership/synchronization, accounts/permissions, contractor close-out, endpoints/infrastructure, billing/analytics and the earlier backend review. It ends with blockers, owner decisions and a dependency-ordered build sequence.

**Newly clarified limits:** ordinary iOS capture does not create canonical backend project/snags; general two-way sync and server memberships are absent. Tested server-created PIN links do not prove iOS PIN publishing; native revoke calls a missing route. The direct contractor status route can bypass manager approval. Snapshot replay protection is conditional on canonical rows. Public Store pricing differs from local StoreKit test data. The handover separates code findings, recorded tests, staging behavior and production facts. No portal or pricing change was implemented for this investigation.

The earlier chapter bundle below remains dated supporting material and does not include this newer handover. Where summaries differ, use the handover's scoped findings. At 22:10 UTC staging health returned 200; production returned 530 / disconnected tunnel. No current signed-device acceptance or production cutover is established.

Updated 9 September 2026. Owner: Daniel. This is the engineering entry point for the iOS app, backend recovery and App Store update. It describes the actual working copies and dated evidence; a design approval is not a release certification.

[Open the engineering folder](https://drive.google.com/drive/folders/1mZcufVqbbLCyjOX_rXC56pMYqVlYXUr0) · [Download the earlier chapter bundle](https://drive.google.com/file/d/13XjSRuYoyYbepiKeL8sk1Vn2Iz77rxlK/view?usp=drivesdk)

## Current state

The approved reskin and icon are in the local iOS source. A replacement Swift/Vapor backend is running in **synthetic staging** on Cloudflare Containers, Neon PostgreSQL and R2, with Resend email. Recorded backend checks passed for sign-in, deletion, server-created PIN links, short links, approval synchronization with canonical snag fixtures, uploads and public synthetic image/thumbnail reads. These passes do not establish ordinary iOS PIN publishing or complete device synchronization.

**Production has not been switched and submission remains on hold.** At 21:35 UTC on 9 September the staging health endpoint returned 200; production `api.snaglist.dev/health` returned 530. No current signed iOS archive or device acceptance exists for this candidate. Contractor email reached Spam. The remaining gates are explicit in the release checklist.

## Read in this order

| File | What it explains |
| --- | --- |
| [01-ARCHITECTURE.md](https://drive.google.com/file/d/1TxprjSyMw3-6NDNbqYcOqWopb5s-7Amt/view?usp=drivesdk) | Repositories, modules, targets, persistence and provider boundaries |
| [02-BUILD-AND-DEVELOPMENT.md](https://drive.google.com/file/d/1pIQ1TARddGiTDGdoKKU0XzzBQEq50wOi/view?usp=drivesdk) | Prerequisites, build commands, safe local tests and review-mode limits |
| [03-PRODUCT-WORKFLOWS.md](https://drive.google.com/file/d/1-zz8Cap97Bu8hjGX6IuRDvlZ4bl7dCt0/view?usp=drivesdk) | Real status values, sign-in, contractor sharing, approval, deletion and photos |
| [04-BRAND-AND-UI.md](https://drive.google.com/file/d/1c5c0vU7WsE2USr2jxsnqTtwAXDC840nz/view?usp=drivesdk) | Current supplied identity, semantic styles, icon and schematic-to-product adaptations |
| [05-ENVIRONMENTS-AND-DEPLOYMENT.md](https://drive.google.com/file/d/1Nh49BS1AWk4H6WAMYJmnH0BJiw9ygSAs/view?usp=drivesdk) | Live staging inventory, secrets, resource limits and proposed production transition |
| [06-TESTS-AND-EVIDENCE.md](https://drive.google.com/file/d/1uVTKWpuY9LxRoMWCCfCDqgryaSZn17Vm/view?usp=drivesdk) | Dated results, initial failures, retests and what has not been proved |
| [07-SECURITY-AND-DATA.md](https://drive.google.com/file/d/13SEkjub9E1J791lylSjaxOd089pSsO6j/view?usp=drivesdk) | Authorization boundaries, fresh-database impact, privacy and remaining defects |
| [08-RELEASE-CHECKLIST.md](https://drive.google.com/file/d/1Q3-Ieb0eSPn5mgX797T3Br2PYQrBT3mC/view?usp=drivesdk) | Prioritized work, owners and evidence required before submission |
| [09-DECISIONS-AND-HANDOFF.md](https://drive.google.com/file/d/1Vm8xnLlhz-v8YD2d8WxIiFAE8JmJwXMV/view?usp=drivesdk) | Decisions, revisions, superseded assumptions and next engineer instructions |
| [evidence/README.md](https://drive.google.com/file/d/1o085nTMxeRX44gvSUNIilxRkrjw8E4ck/view?usp=drivesdk) | Downloadable redacted results and their scope |

This folder mirrors a repository documentation directory: numbered Markdown chapters, a README and an evidence subfolder. Relative links work in the downloadable documentation bundle; the Drive copies use direct Drive links. It is a dated documentation snapshot, not an automatic repository mirror. Update the same Drive IDs after meaningful changes, and refresh the evidence date and status together.

## Sources and authority

The [knowledge-bank START HERE](https://drive.google.com/file/d/1nigqo22baHKY_O9zKJLm2JSccwl8VVPs/view) remains the cross-project index. Daniel's explicit instructions control task scope. The [current brand guide](https://drive.google.com/file/d/1fd226EU2FkvrJZoBAKt36lqkEdNSMNfq/view) and supplied ZIP control visual identity; the [commercial register](https://drive.google.com/file/d/1U3I8of2FJtRtge1ohl5vP0ra9lJbCc3n/view) and later commercial amendments control offers and claims. Research/roadmap documents are not evidence of implemented features.

These engineering documents supersede earlier handoff statements that all backend work is local, that no staging exists, or that recovering the disabled Hetzner database is required. They do not replace the marketing plan or declare production ready. No source code, secret values, usable authentication tokens, customer records or original customer photos are uploaded with this documentation.
