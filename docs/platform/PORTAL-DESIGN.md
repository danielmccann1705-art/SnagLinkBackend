# Snaglist portal design system

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

## Contractor design implementation now inspected

The canonical renderer in backend `Sources/App/Resources/Contractor/` extends the established design system. It uses the supplied v2 outlined wordmark, Plex type, labelled status hierarchy, explicit before/after images and a simple mobile evidence form. The initial older wordmark was caught during side-by-side inspection and removed; final captures use the current supplied identity. A single original photo now has useful inspection size. Draft filenames/notes survive ordinary navigation, keyboard photo enlargement returns focus, and submission is visibly distinct from awaiting review and accepted closure. The local review gallery puts connected evidence first and labels older simulated samples separately.

Final captures are `contractor-pin.jpg`, `contractor-register-desktop.jpg`, `contractor-submission.jpg`, `contractor-manager-review.jpg`, `contractor-accepted.jpg`, `contractor-mobile.jpg` and `contractor-empty.jpg` under `outputs/portal-design`. The awaiting-review trace was captured before final header correction and is historical functional evidence. Continuous workflow recording, fresh native/report comparison, physical-device/zoom and real staging D2 are still required.

## Historical checkpoints and retained source detail

The following records describe their dated revisions. Present acceptance is stated above and in the linked current verification report.

## Earlier checkpoint — manager review, 11 September 2026

Backend application `7b4c8cd` now passes **226 tests, zero failures/skips**, on a fresh isolated Neon PostgreSQL 16 database; all eight workflow cases also pass independently. Portal `455c3e1` builds and passes **31 tests**. Actual browser review verified private before/after evidence, historical attempts, retained notes, accepted closure after reload and stale competing-decision rejection. A discovered no-op conflict button was replaced with a clear explanation and readable retained note. Responsive iframe widths 320/390/768/1024 showed no horizontal overflow; this is not physical-device or zoom acceptance.

The new synthetic-only Neon Free test project is separate from recovered staging. A restricted, endpoint-pinned runner leaves the original local-only guards unchanged. Interactive email is intercepted locally; no external message or production deployment occurred. Native full-build, canonical Contractor links, full sync, D1 recording/native PDF, real G1/D2 and remaining work packages stay open.

Dan also explicitly added Google sign-in on iOS/web and comprehensive company administration for Team plans. See [Google sign-in and team administration scope](https://drive.google.com/file/d/1uM-7BkQd8ID5btihXfoL9BAe1uE1FvUg/view) and the [connected review verification report](https://drive.google.com/file/d/127OOiTiWcKU904asY9rjpOB8-3c5Bu1O/view) for evidence, runtime boundaries and next dependencies. Earlier database-unverified statements below describe the 10 September checkpoint and are superseded by this executed verification; no whole package or release gate is complete.

Candidate date: 10 September 2026. Stage: D1 reference and interaction gate. Real staging gate D2 remains outstanding.

## Authority and source inspection

The [implementation brief v1.1](https://drive.google.com/file/d/1d7H-EvCfdrc0GVPGnNEXHhJVeG-SbOlL/view), revision note, all of §12, WP-07/WP-08, G3 and §22 were read. The [current brand guide](https://drive.google.com/file/d/1fd226EU2FkvrJZoBAKt36lqkEdNSMNfq/view) and [supplied Snaglistv2.zip](https://drive.google.com/file/d/1yPWz3XhSAS6yi_SYJ7uQAelp5Q6B9ctY/view) control visual identity. The archive's verified SHA-256 is `daeabab5f721567cd0359527b24b0179449b43332d9ff9ce21967a6c3eb84468`. Earlier assistant-created v2 packs are superseded.

The source ZIP's extracted identity, native screen, contractor and PDF templates were inspected as source. Existing raster identity references and actual simulator captures were inspected visually. A direct browser visit to the extracted identity HTML was blocked by browser URL policy; that page was not reopened using an alternate URL or browser. The new portal screenshots are actual renders of this application's localhost UI, not claims that the blocked source canvas was rendered.

| Source | Observed visual/product treatment | Web mapping |
| --- | --- | --- |
| ZIP `02 Stage 1 Identity` and current brand guide | Outlined Plex wordmark, Marker pin, four supplied pin geometries, restrained light surfaces | Copied approved SVG geometry; no CSS imitation of the wordmark; self-hosted fonts and semantic colour tokens |
| Native `Shared/SnaglistBrandCore.swift`, `Snaglist/Utilities/SnaglistBrand.swift` | Shared colour/type roles; plain, clear controls; pin plus readable status | Shared CSS tokens, `StatusLabel`, semantic button and form styles |
| Native `Snaglist/Views/Projects/ProjectSnagListBrand.swift` and `outputs/refined-list/after-populated.png` | Original defect thumbnail, reference, title, description, location, status; add/share actions | Desktop table with reference/title/photo, plot/location, contractor, date and status; narrow card equivalent; dedicated detail workspace |
| Actual manager review capture `outputs/approval-brand/after-manager-detail.png` | Completion evidence and explicit internal approve/send-back actions | `Review` workspace with full before/after images, contractor attribution, review confirmation and required send-back reason |
| Backend `Sources/App/Services/WebReportRenderer.swift` | No-account contractor reads, start work, evidence/notes submission; still contains older card styling | Mobile contractor sample uses the same tokens and status language. Existing live renderer has not yet been replaced |
| Native `Snaglist/Views/Reports/ReportsView.swift`, PDF generation around lines 787–912 | Cover, grouped snag entries, original/completion media, plans, final PDF; based on native local records | Plan consistent references, status labels and before/after captions for server-issued artifacts. Report generation is not implemented in this portal sample |
| ZIP `05 Stage 5 PDF Report` | Restrained A4 schedule, thin rules, Mono references, paired evidence appendix | Corresponding table rules, type hierarchy and evidence labels; schematic gradients and prototype status/pricing are not copied as facts |

Native implementation still uses legacy workflow enum values. The proposed five states are introduced in this isolated web design model only; no global native rename or production data migration has occurred.

## Tokens

| Role | Value | Application |
| --- | --- | --- |
| Primary action | Marker `#D8321E`; pressed `#B72A19` | Add snag, accept fix, submit for review; white text |
| Text | Ink `#1A1D23` | Main task content, controls and focus outlines |
| Canvas / raised | Stone `#F7F8FA` / White `#FFFFFF` | Work surface, table and detail panel |
| Secondary text | `#59616D` | A slightly darker semantic text role for small metadata on Stone |
| Brand grey | `#6B7280` | Secondary geometry and appropriate large/background text contexts |
| Rules / control boundary | `#D9DCE1` / `#9299A3` | Quiet separation; stronger necessary form/control outlines |
| Accepted closure | Moss `#1F7A4D` | Closed status/acceptance record only; never a pending submission |
| Typography | IBM Plex Sans 400/500/700; Plex Mono 400 for references only | Root-relative type, no network font dependency |
| Shape | 6 px controls; 0 px photo corners; square thumbnails | Review images retain their source aspect ratio without decorative rounding |
| Spacing | 4, 8, 12, 16, 24, 32, 48 px | Common spacing vocabulary |

White on Marker has approximately 4.78:1 contrast. Stone on Marker is approximately 4.50:1 but falls slightly below 4.5 without rounding, so primary actions explicitly use white. Typography and controls still require the full D2 accessibility checks; these values alone do not establish conformance.

## Information and interaction model

The full target navigation remains Overview, Projects, Snags, Reviews, Contractors, Reports plus company administration. D1 exposes the implemented Snags/Reviews samples and a separately labelled contractor sample. Unimplemented destinations are not presented as working navigation. The company, project and synthetic identity remain visible; company membership is not inferred from this UI.

- Register: table on desktop, cards below 768 px. Search, status, plot, contractor and overdue controls. Counts derive from the same fixture collection. Selection is independent of row opening; a filter change clears selection with feedback, while ordinary detail/review navigation preserves it. Bulk controls state the selected count and project. All loaded design rows fit on one page; this is not the future 5,000-snag performance implementation.
- Detail: 440 px nonmodal panel at 1440 px and above. Smaller viewports use a native modal dialog with Escape dismissal. The panel leads with the original defect and a conspicuous evidence-review action. Unknown/missing photos are explicit. Long content remains available in the detail.
- Review: paired full images, zoom dialog, original requirement, submitted note, self-reported contractor name and identified internal reviewer. Accept fix opens an explicit closure confirmation. Send back requires a reason. The record remains on screen after a decision rather than jumping automatically to another snag.
- Context: filters and selected snag live in the URL. Selected rows remain in React state across sample navigation. Notes are drafts scoped to the snag; browser-session storage is only a development convenience. Return-to-register retains route and scroll. Real online browser drafts must be tied to authenticated account/workspace and removed appropriately on logout/access removal.
- Contractor: no account or purchase surface. Original defect, location, clear requested changes, after-photo requirement and a completion note. Submission confirmation says awaiting review; acceptance identifies closure. File selection in this design build is local only and is never labelled as a server upload.
- Controls: semantic HTML table, native form controls and `dialog`; visible focus, explicit names, British English and sentence case. No ARIA grid, drag-only control, confetti or decorative KPI dashboard.

## Synthetic data and evidence provenance

The sample is Willow Court, Plots 1–24, Reading, with twelve stable references (`SL-142`–`SL-153`). Alder & Field Construction, Emma Hughes, Jamie Taylor and the contractor companies are fictional. The due-date baseline and initial fixture history use 10 September 2026; new submission and decision events record their actual UTC time and display it in Europe/London. No customer records or email recipients are used.

The three original defect images were generated for the native development fixtures on 7 September. They are not proof of a real customer's defects. The new `door-after.png` was generated on 10 September by editing the synthetic door image to show the specified repair while preserving composition. It is explicitly fictional after evidence. Defect photos are never automatically reused as repaired evidence. Missing photos stay missing. The historical closed example is visibly qualified as a historical record without a recorded acceptance or after evidence.

Fixture code and images are imported only through the development-only entry. Production build tests assert that names, sample mutation controls, local fixture-store keys and synthetic image files are absent from the build. No successful production sign-in or write is simulated when an API is unavailable.

## Integration obligations

Before broad screen rollout, complete and record D1 defects and interaction checks. Then replace fixture commands with the versioned Vapor contracts, server-confirmed decisions, canonical IDs/revisions, secure sessions and centrally generated capability hints. Contractor grants and media checks remain server responsibilities. Do not translate local design state changes into a client-side authorisation system.

D2 needs actual staging data created through the ordinary iOS capture/sync journey, a second authenticated manager, a scoped no-account contractor, processed private evidence, decisions returning to the app, and a current report. Fixtures cannot satisfy those gates. The outstanding work is tracked in `PORTAL-DESIGN-REVIEW.md` and the controlling WP-01 through WP-11 brief.


## D1 implementation continuation

The fixture adapter now retains photo and note drafts per snag in a tab-scoped IndexedDB sample. This storage is development-only and is removed from the production bundle together with the fixture entry point. It must not be mistaken for the planned authenticated, account-isolated durable sync implementation.

Shared controls now include native checkbox mixed state and 44 px fine-pointer / 48 px coarse-pointer targets; mobile evidence actions remain 52 px. Thumbnail treatments stay square. Side-by-side register metadata can visually truncate to two lines while the detail exposes the complete text. Review headings and recorded UK timestamps follow the actual decision state. Contractor submission, awaiting review and accepted closure remain separate.

The maintained review log records actual file-picker, reload, repeat-submission, acceptance/history, keyboard, 320/390/1024/1440 and page-zoom observations. D1 remains open for the explicitly listed final checks and recording; D2 is not started.

## Connected review candidate — 10 September 2026

The connected register/photo milestone at `1e8e387` was exercised in the actual local browser. `f763ae2` adds a full review workspace using the existing D1 evidence-pair, context, decision-panel and history treatments, authenticated private image viewers and generated workflow contracts. Notes and historical-attempt selection remain in the account-owned controller; uncertain decisions retain one immutable request. Actual rendering/interaction review of this new component is still pending the database runtime. Do not treat controller tests as D1/D2 visual acceptance.
