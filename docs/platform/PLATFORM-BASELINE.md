# Platform baseline — 11 September 2026

## Current checkpoint — manager Add snag, 11 September 2026

Portal **ae5c7f2** (`feature/unified-portal`) now logs canonical snags from populated and empty projects, preserves drafts across ordinary project navigation and retains register filters. Create and publication are separate confirmed writes with immutable retry IDs and explicit conflict recovery. The exact source passes the production build, contract/type checks and **59 portal tests, zero failures/skips**. Actual browser use and read-only database checks verify two distinct synthetic Open records, the saved deadline and reload. The 320/390px form fits without horizontal overflow; captures use measured dimensions.

Read [MANAGER-SNAG-CAPTURE.md](https://drive.google.com/file/d/1AhumBnhItkMukocURVbOEgFb0D4eB1Jr/view), the [actual capture/test bundle](https://drive.google.com/file/d/17E0-i04geR9xnSt79Y6y0VK_ll0qe0N0/view), and [NEXT-SESSION.md](https://drive.google.com/file/d/1MoUSx6EI3ghXDWT4fW8kgjgGKZBSPzV9/view) for source/files, verification limits and the dependency-ordered continuation. The report distinguishes real local Vapor/isolated Neon from deployed staging. No new photo or Contractor link was attached to these two records. Drafts are retained in this tab, not a durable offline queue.

**Native Google:** application **f9fb682** builds/runs in Xcode; **148 tests pass, 10 historical tests skip, zero fail**. Actual native provider exchange remains unverified. Google web provider linking/sign-in is verified locally. **Next:** account-partitioned native data and complete sync/import; manager assignment/share/link/archive workflows; matching Linux/private-R2 staging and real native Google; complete company workbench/seats/test commerce, reports/jobs and G1/D1/D2. No whole platform/release gate passes from this slice, and no merge, push, production cutover, live billing or App Store action occurred.

Earlier checkpoints below retain their dated evidence. The concise [continuation file](https://drive.google.com/file/d/1MoUSx6EI3ghXDWT4fW8kgjgGKZBSPzV9/view) describes the current outstanding work.

## Earlier checkpoint — native Google implementation, 11 September 2026

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

## Reproducible application source

| Repository | Branch | Application commit |
| --- | --- | --- |
| `/Users/danielmccann/Desktop/Projects/SnagLinkBackend` | `feature/unified-platform` | `fb42916` |
| `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal` | `feature/unified-portal` | `de215b1` |
| `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink` | `feature/unified-platform` | `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc` |

Documentation commits may follow these application checkpoints. No application commit here is a pushed/merged/deployed image. Backend contract is 0.8 candidate: 53 paths, 66 operations, 73 schemas. Portal generated transport types match. Full graph/native API parity remains incomplete.

Original bases were backend `022877e38bc19935e5ed8fdead7ea6215abb1916`, native `941b635ce2c1ddbc1b8ee72386d600d015c695a1`, portal `026014d2f36f49220652fbd8f993072ce0fa3a73`. Prior branches were not reset. `work/unified-platform/baseline/manifest.json` records the original status, binary diffs and source/asset archives before edits. The backend's unrelated local agent settings and duplicate staging-example file remain untracked and untouched. No credentials were committed in this milestone's scan.

The native checkpoint includes 90 changed/new files, most preserving earlier approved work. The bundled upstream font licence has one original trailing-space line; it was retained unchanged. Application-source whitespace checks pass.

## Environment and release boundaries

The separate Neon Free PostgreSQL 16 project `dawn-queen-24474678` in London now supplies fresh restricted-role/TLS integration tests. The pinned runner creates only synthetic `snaglist_platform_test_*` databases, verifies an empty default database and refuses a ninth retained test database. Its runtime and exact-source results are documented in CONTRACTOR-LINK-REVIEW.md. The original local-only runner guards remain unchanged.

The actual interactive host uses the same source on `127.0.0.1:55486`, Vite `127.0.0.1:5177`, synthetic Neon database `snaglist_platform_test_0910222943_fc44` and task-local private media. Only synthetic email is intercepted by its test harness; no external mail is delivered. Secrets and capabilities remain outside Git/Drive. This is not a public deployment or private-R2 verification.

Historical local PostgreSQL on `127.0.0.1:55439` became unusable, OrbStack requires its own terms/privacy setup, and a task-local source build hit sandbox shared-memory denial. No global reset was performed. Original `55480`/`5176` development configuration remains as documented in the earlier reports; do not point it at a remote/customer environment.

Recovered Cloudflare staging Worker/Neon/R2/Resend remain at the 9 September infrastructure baseline; this continuation did not redeploy them or freshly establish their health. Production has not been cut over. Native source remains version 2.0.0/build 2; the currently released App Store version/build and installed public behaviour were not reverified here.

Staging iOS has distinct app/Clip bundles, SwiftData location, OS preferences/media/queue sandbox and Keychain service, with production purchases/push/shared widgets disabled. Account partitioning within an installation is still WP-06 work. Full native build remains unverified after earlier package/CoreSimulator environment failures; no customer migration or ordinary native sync success is claimed.

## Evidence and next work

Current implementation/security detail: CONTRACTOR-GRANTS.md. Source-specific tests, fixture path, screenshots, actual actor/evidence readback and limits: CONTRACTOR-LINK-REVIEW.md. Full package inventory: PLATFORM-ACCEPTANCE.md. Authorised Google/company scope: GOOGLE-SIGN-IN-TEAM-ADMIN.md.

Workspace evidence is under `/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/portal-design/` and `outputs/app-store-prep/backend-tests/`. The current review index separates connected captures from earlier simulated design samples. Preserve the supplied v2 brand guide/ZIP and existing native reskin/icon; the old assistant-created identity is superseded.

No package or G1–G5/D1–D2 release gate is complete. Continue native graph/sync and identity lifecycle, manager publication/sharing, company administration, jobs/reports, test commerce and staging acceptance in dependency order.
