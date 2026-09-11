# Portal design review

## Current checkpoint — Google web sign-in, 11 September 2026

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

## Contractor design implementation now inspected

The canonical renderer in backend `Sources/App/Resources/Contractor/` extends the established design system. It uses the supplied v2 outlined wordmark, Plex type, labelled status hierarchy, explicit before/after images and a simple mobile evidence form. The initial older wordmark was caught during side-by-side inspection and removed; final captures use the current supplied identity. A single original photo now has useful inspection size. Draft filenames/notes survive ordinary navigation, keyboard photo enlargement returns focus, and submission is visibly distinct from awaiting review and accepted closure. The local review gallery puts connected evidence first and labels older simulated samples separately.

Final captures are `contractor-pin.jpg`, `contractor-register-desktop.jpg`, `contractor-submission.jpg`, `contractor-manager-review.jpg`, `contractor-accepted.jpg`, `contractor-mobile.jpg` and `contractor-empty.jpg` under `outputs/portal-design`. The awaiting-review trace was captured before final header correction and is historical functional evidence. Continuous workflow recording, fresh native/report comparison, physical-device/zoom and real staging D2 are still required.

## Historical checkpoints and retained source detail

The following records describe their dated revisions. Present acceptance is stated above and in the linked current verification report.

## Earlier checkpoint — manager review, 11 September 2026

Backend application `7b4c8cd` now passes **226 tests, zero failures/skips**, on a fresh isolated Neon PostgreSQL 16 database; all eight workflow cases also pass independently. Portal `455c3e1` builds and passes **31 tests**. Actual browser review verified private before/after evidence, historical attempts, retained notes, accepted closure after reload and stale competing-decision rejection. A discovered no-op conflict button was replaced with a clear explanation and readable retained note. Responsive iframe widths 320/390/768/1024 showed no horizontal overflow; this is not physical-device or zoom acceptance.

The new synthetic-only Neon Free test project is separate from recovered staging. A restricted, endpoint-pinned runner leaves the original local-only guards unchanged. Interactive email is intercepted locally; no external message or production deployment occurred. Native full-build, canonical Contractor links, full sync, D1 recording/native PDF, real G1/D2 and remaining work packages stay open.

Dan also explicitly added Google sign-in on iOS/web and comprehensive company administration for Team plans. See [Google sign-in and team administration scope](https://drive.google.com/file/d/1uM-7BkQd8ID5btihXfoL9BAe1uE1FvUg/view) and the [connected review verification report](https://drive.google.com/file/d/127OOiTiWcKU904asY9rjpOB8-3c5Bu1O/view) for evidence, runtime boundaries and next dependencies. Earlier database-unverified statements below describe the 10 September checkpoint and are superseded by this executed verification; no whole package or release gate is complete.

Historical dated observations and source detail follow. Use the current checkpoint above for present verification status.

Date: 10 September 2026. **D1 in progress. D2 not run. Portal not complete.**

This document records actual browser observations and will be updated as the same implementation campaign progresses. Synthetic local interactions do not establish API correctness, multi-user access or staging acceptance.

## Findings and corrections so far

| Observation | Correction / status |
| --- | --- |
| Initial detail layout put the evidence-review action below secondary metadata | Moved review callout before assignment/date metadata and reduced thumbnail height |
| Initial review layout used too much vertical space and pushed decisions down on a laptop | Tightened heading/subject spacing, removed a decorative shield, compacted metadata; reinspection underway |
| File watcher did not invalidate changed source in the sandbox; refresh served old transforms | Enabled loopback development polling, restarted Vite, confirmed current asset paths and actual loaded images |
| An entered date could be visible in the native date input while the form retained an old state value | Form submission reads the named date input through FormData; browser recheck applied the entered 18 September to exactly eight selected snags |
| Historical closed example could imply an evidenced acceptance in the list | Added Historical record qualifier; detail states no recorded reviewer or after evidence |
| Original fixture images would have been copied into production from Vite public assets | Moved fixtures behind the development-only module import; production output test added |
| Contractor after-photo selection initially did not retain evidence for review | Store the selected local image/name/note with the synthetic submission; no real upload claim |
| No clear next action above a long mobile form | Added a 52 px completion-evidence action that hides once the form is visible |
| Inherited website development dependencies had security advisories | Removed unused Tailwind dependencies and applied compatible fixes; npm audit reported zero vulnerabilities |

## Observed checks

- Build, strict TypeScript compile and six regression checks passed after the workflow/history corrections. The latest desktop side-panel, phone evidence form, tablet detail and 200% zoom treatments have now been captured and inspected.
- Chrome actual browser at 1440×900, 1366×768 and 390×844 inspected.
- Plot 12 + Cedar Joinery + Overdue returned only the expected sent-back snag `SL-144`.
- Closing its detail retained all three URL filters.
- Eight-row assignment scope was presented in a confirmation form; local assignment applied to the selected rows. The date regression recheck passed with the exact entered date.
- Contractor submission without an after photo showed an actionable error and retained the completion note.
- A direct headless browser launch from the shell was denied by the macOS sandbox. The already-authorised Chrome browser tool remains usable for real UI inspection and captures. No claim of a headless test pass.

## Further corrections and tool limitations

- Replaced hard-coded decision dates with event-derived UK timestamps. Repeat submissions now retain previous photos, notes and decisions in an append-only development history. Four pure development-model tests exercise evidence requirements, duplicate submission/decision rejection and complete send-back/resubmission/acceptance history. This is not a server implementation.
- Moved Review evidence into the detail header, so its placement does not depend on description length. Raised essential metadata to 13 px and enlarged checkbox label targets to 44 px with a native mixed-selection state. These changes were reinspected in the subsequent native Chrome walkthrough.
- The file chooser attempt stalled and reset the browser tool. Its documented Chrome upload guidance asks for the ChatGPT extension’s Allow access to file URLs setting. This was reported to Dan; the setting was not changed automatically. Subsequent browser attachment/Playwright calls also timed out or reported an unattached debugger. Native accessibility controls could still open the snag and expose its review action.
- The saved `interrupted-walkthrough.mp4` is a 24-second sequence of six actual browser captures, held four seconds per step. It stops before contractor upload, predates the history/date corrections and is explicitly not an acceptance recording or a measure of task completion time.
- The native Chrome controls subsequently recovered the blocked interactions; see the dated continuation below. A continuous screen recording remains unavailable.

## Remaining D1 checks

Finish the continuous workflow recording and outstanding native PDF/output comparison. The final selection/empty-scope checks and provisional component rubric are recorded below. Keep D1 open until its remaining evidence is complete. D2 still requires the integrated side-by-side native/portal/contractor/report comparison and real permission/conflict states.

## D2 / integration status

Not run. No manager portal session, shared company project, canonical synchronisation or real staging write has been added by this D1 sample. Still required: server permissions and conflicts, API failures/loading/offline/access removal, invitation/membership, private media, durable decisions/history, reports, remaining v1 navigation, server pagination/performance, browser matrix and native-to-browser acceptance journey. Refer to the controlling brief's G1–G3 and WP-01–WP-11.

Actual captures live in `../outputs/portal-design/` alongside the review evidence pack. Current captures are source evidence, not product usage or customer research.

## Independent backend progress

The profile route now rejects changing a sign-in email without verification; a case-equivalent unchanged address still permits name edits. Email token exchange matches a normalized address and rejects ambiguous legacy duplicates without consuming the one-use token. Four new identity-guard tests plus 29 relevant existing authentication/allowance tests passed against an isolated PostgreSQL database (33 total, no failures/skips). No provider credentials or email delivery were used, and the disposable container was removed. These guards do not implement browser sessions or the planned proof-based identity linking/recovery flow.

At 14:55 UTC, both automated health requests returned Cloudflare 403/1010, an access block for the requesting client, not evidence of backend health. [Cloudflare’s 1010 documentation](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/) explains this distinction. Current staging and production application health are therefore unverified by this check; no security setting was disabled.


## Continuation — native Chrome walkthrough, 10 September, 16:06–16:45 BST

Chrome’s browser bridge remained unavailable, but native accessibility controls, the ordinary file picker and Chrome’s built-in responsive controls worked. No extension permission or browser security setting was changed.

Verified by actual UI interaction:

1. Opened SL-142’s review and requested a close-up of the lower hinge with a mandatory reason.
2. Opened its contractor view and saw the same reason and the actual UK decision time (16:08).
3. Chose the synthetic `door-after.png` through the macOS file picker and added a completion note.
4. Reloaded the page. The selected snag, photo preview and full note returned.
5. Submitted at 16:10. The contractor view showed **Submitted. Awaiting review.** and did not close the snag.
6. The manager saw **Attempt 2**, the new photo and the exact completion note. Explicit confirmation accepted the fix at 16:13.
7. History retained initial logging, first submission, send-back reason, second submission and acceptance, with both attempts’ evidence available.
8. At 1024 px, the long electrical snag name, full contractor name and unavailable-photo explanation fitted in the focused detail. Enter opened it; Tab reached its working note; Escape restored focus to SL-145’s row.
9. Closing/reopening Add snag retained “Seal the shower tray edge” as an unsubmitted draft. The empty project’s Contractor link action is disabled with an explanation.
10. At 390 px, Add completion evidence scrolled to the form; the sticky action then disappeared and did not cover the form or submit control. At 320 px the accepted review and full history stacked without horizontal clipping.
11. Chrome’s real page zoom displayed **200%**; controls and the register reflowed without page-wide horizontal clipping. Zoom was restored to 100% afterwards. Viewport testing used Desktop mode for the final 1440 capture and Mobile mode for the 390 capture; older responsive captures used Chrome’s default emulated mobile mode.

The test was conducted by the implementation agent with synthetic data. These are observed functional steps, not a timed first-user usability study, provider delivery proof or staging acceptance.

Additional implementation corrections:

- Synthetic drafts and submissions now persist in a tab-scoped IndexedDB sample instead of putting several megabytes of image data into sessionStorage. Save failures retain in-memory state and display a warning; this is **not** the production offline queue.
- Photo drafts are keyed by snag and retained across navigation/reloads; a slow file read writes to the snag selected when it began.
- Add-snag drafts survive ordinary dismissal. Contractor preview uses app navigation, preserving register state.
- Filter changes clear selection with feedback; detail/review navigation keeps selection. The final browser check passed: after selecting SL-142, entering “door” cleared selection and displayed the reason.
- Accepted/sent-back review headings reflect the resulting state, and the decision card displays the recorded timestamp.
- Native file input is hidden from the accessibility tree to avoid a contradictory “No file chosen” control beside a restored photo preview.
- Thumbnails remain square at all breakpoints; long contractor labels are limited to two visual lines in the compact side-by-side register, with the full name in detail. Coarse-pointer controls have 48 px targets; the primary mobile evidence action stays 52 px.
- A contractor view with no assigned snag now has a deliberate empty state instead of dereferencing a missing fixture. The browser check passed after creating a synthetic unassigned snag using Add snag, then opening the contractor view.

Actual capture index: `../outputs/portal-design/index.html` and `CAPTURES.md`. The original 24-second interrupted slideshow remains historical evidence only. An attempt to use the macOS screen-recording app timed out; **no continuous workflow recording is claimed**.

## Permission foundation — implemented, unit-tested, not integrated

`ProjectAccessPolicy.swift` and `ProjectAccessPolicyTests.swift` implement the v1.1 role matrix as a server-side policy primitive. Thirteen tests passed after compiling the current backend source. They cover private personal projects, removed creators/owners, cross-workspace/project/user grants, Manager versus Member rights, owner-only company actions and the own-unpublished-draft exception. No database/provider was contacted for these tests.

The primitive is not yet connected to controllers, database memberships, invitations, media or background jobs. It therefore does **not** establish WP-02 or G1 acceptance. Do not activate company sharing until those paths use transaction-loaded server context and the complete permission audit passes. Target-member restrictions, last-owner protection and concurrency checks belong to the forthcoming command layer.

## Infrastructure observation update

The existing in-app Cloudflare dashboard session was refreshed successfully. Current settings show `STAGING_ENABLED=true` and `STAGING_EMAIL_ENABLED=true` (the initial cached page had stale false values). Secret values remained encrypted and were not revealed. Opening the staging health URL in the browser returned `net::ERR_BLOCKED_BY_CLIENT`. The earlier automated HTTP health checks returned 403/1010. Application health remains unverified; dashboard access is available and does not need a new sign-in at this point. No security setting, routing or deployment was changed.


## Final D1 interaction checks and provisional rubric

Completed after the preceding evidence pack was first published:

- Selecting SL-142 and searching “door” returned six matches, removed the old selection, and displayed “Selection cleared because the filters changed.”
- Add snag from an empty project created one synthetic unassigned snag through the ordinary form. The contractor sample then showed “No assigned snags” and advised contacting the project manager; it did not crash or expose the earlier sample’s assignments.
- Native accessibility clicks on page buttons were unreliable while Chrome’s responsive emulation was scaled down. The form operation was verified in the normal desktop browser. Phone captures and the evidence-jump interaction were inspected at 100% emulation scale. This is a tooling limitation, not evidence that a real touch device passed every action.

Provisional D1-only agent assessment, using the brief’s seven dimensions. These are observed design judgements, not customer validation or G1–G3 acceptance.

| Dimension | D1 score | Observed basis / remaining scope |
| --- | --- | --- |
| Snaglist continuity | 4/5 | Supplied SVGs, Plex type, Marker/Ink/Stone, restrained rules and shared status treatment; native/report semantic differences remain in D2 scope |
| Hierarchy and density | 4/5 | Actual 1366/1440 register/review inspection; secondary metadata tightened and long contractor labels controlled; 440 px detail keeps its review action visible |
| Task clarity | 4/5 | Explicit Contractor link, evidence requirement, send-back reason, awaiting-review confirmation and acceptance confirmation |
| Interaction quality | 4/5 | Notes/photo survive reload, Add draft survives dismissal, filters/selection behave as specified, keyboard focus returns to the original row |
| Evidence and trust | 4/5 | Two attempts and separate decisions retained; missing media and historical closure qualified; actual issued-report parity remains unverified |
| Accessibility/responsiveness | 4/5 | Keyboard dialog walkthrough, 320/390/1024/1440 captures, 200% browser zoom and larger touch controls; full real-device/accessibility audit belongs to D2 |
| Finishing quality | 4/5 | Square thumbnails, readable status labels, completed/empty/long-content treatments inspected; no claim of a finished portal or passing live integration |

D1 remains **open** despite these provisional scores: the continuous recording is missing and actual native PDF regeneration/output parity is not verified. Do not treat an average score as a waiver of those limitations.

Additional source comparison: inspected the existing native App Clip report capture `outputs/approval-brand/after-clip-report-evidence.png`. It uses larger card-based presentation and a **Completed** counter. The current backend printable route `/api/v1/magic-links/:linkId/pdf` emits HTML and uses **Approved** for accepted work; the portal uses **Closed** with explicit acceptance attribution. Those names are not yet a cross-surface canonical contract. The native PDF generator was inspected as source, not rerun successfully in this continuation. Reconcile states and compare fresh outputs in D2; do not label the HTML endpoint as a generated PDF.


## Connected register checkpoint — 10 September, later local candidate

Backend `7ddbc3a`, portal `3c19fae`, native unchanged `c4b8360`. This adds real local HTTP/PostgreSQL behaviour to the preserved design sample; it is not D2 or G1 staging acceptance.

- Used the real email request, one-use confirmation, cookie session, project list and register endpoints. Emails stayed in a DEBUG-only local mailbox for a synthetic example.test account. No external email was sent.
- Opened 12 API-created construction snags, switched between details with an unsaved location draft, returned and saved, then verified persistence after reload.
- Two browser tabs made competing edits under one synthetic account. The stale save returned a conflict with current/proposed values; save remained disabled until explicit rebasing, followed by a successful deliberate save. This is not a two-distinct-internal-user test.
- Inspected the zero-snag project through the same real data path. The empty state still needs the real Add snag action.
- Captures: `../platform/connected-register-local.png` and `../platform/connected-register-conflict-local.png`. They are actual browser captures. The conflict capture identified excess empty space before the edit form; the subsequent candidate hides the unloaded-evidence placeholder during editing.
- Generated contract check, TypeScript, production build and all 20 tests pass. Vite's default config bundler stalled on this host; the supported native config loader succeeds and is now the explicit build command.

Still open: protected evidence, creation/share/review/bulk operations, full filters/selection, integrated keyboard/narrow/zoom/error/permissions checks, fresh native/report comparison and continuous workflow recording. These captures do not replace or certify the full approved workbench sample.


## Historical checkpoint — private media and review, 10 September 2026

Backend `7b4c8cd` (workflow candidate; private-media base `6d742bf`); portal `f763ae2` (review candidate; private-photo base `1e8e387`); native `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`. Local branches only; no deployment/release.

**Verified locally:** private original/processed media, authenticated gateway, revisioned capture attachments, real portal photo upload/thumbnail/enlarge/reload. Backend full suite 218 pass before the last register-preview addition, then seven relevant cases pass; portal build and 31 tests now pass.

**Implemented but unverified in the database/browser:** canonical attempts, decisions, evidence consumption, reasoned waiver/internal fix/reopen, queued notifications, completion-history snapshots, transaction-grouped deltas and the connected review workspace. All backend application/test code compiles. The eight new workflow tests failed at database setup, so none is a workflow pass. The new review workspace still needs actual browser rendering/interaction inspection; the earlier connected-photo capture is separate evidence.

**Current blocker:** OrbStack/Docker's task database stopped responding and the OrbStack app shows setup requiring Dan's acceptance of its terms/privacy. A separate official PostgreSQL 16.15 source build succeeded, but the sandbox denied shared-memory initialisation. Neither path currently supplies a working test database. Existing databases/other projects were not reset. Native build still has its separate package-sandbox/CoreSimulator block.

See [WORKFLOW.md](https://drive.google.com/file/d/1x8NH7hxbBjoeyv65CUVfEuE-_iytKfZB/view) for architecture, exact file/symbol references, test labels and resumption instructions; [PRIVATE-MEDIA.md](https://drive.google.com/file/d/1h3md2ZhJ4rlrJdakMHsKEwTD0o36riEP/view) for upload/storage boundaries. D1 recording/fresh native PDF, real D2 and G1–G5 remain open. Earlier dated sections are historical checkpoints, not claims that later code passed their tests.

### Connected photo and review evidence

The latest actually inspected connected capture is `outputs/platform/connected-register-private-photo-local.png`: a real synthetic photo upload, thumbnail, full-fit image and enlarged viewer after reload. Source: backend `6d742bf`, portal `1e8e387`. This extends the earlier register/conflict checks.

`ConnectedReview.tsx` now reuses D1's full-width evidence pair/context/decision layout, existing type/status/token system and enlarged-image treatment. It supports history selection, retained notes, server-acknowledged acceptance, reasoned send-back/reopen and explicit stale-evidence review. **No actual browser render/capture of this new component has been completed because the local database is unavailable.** Inspect it before accepting its density, image comparison, keyboard/zoom/mobile behaviour. Current 31-test build success is functional source evidence only.

Do not relabel the old still-image sequence as a continuous recording. D1 remains open; D2 still needs real staging and cross-surface comparisons.
