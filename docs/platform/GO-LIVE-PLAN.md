# Snaglist iOS and manager portal — go-live plan

## Current readiness checkpoint — 11 September 2026, 21:03 UK drawing foundation

**The unified app and portal are not ready for production release.** The [resumed build checkpoint](https://drive.google.com/file/d/11WKawuHlUmVmjtgLQZrUfuGZ0A9YyM_g/view) supersedes older progress statements below; dated historical evidence is retained.

- Native `339203a`: real staging build passed, **331 tests passed, zero failed, five existing skips**. This retains verified recovery, account-bound subscription handling and server-confirmed Contractor link revocation, adds the shared [drawing read fix](https://drive.google.com/file/d/1daX19SC23uwH0X39Pho-U7lRtpTWp3vV/view) and tested [scope coordinator](https://drive.google.com/file/d/10MtNmcxEVph3KI-Gshd1MgDqxhERKKsd/view). **Live account store/media/task partitioning, explicit legacy import and complete native capture sync remain incomplete.** Actual drawing import/upload and full D2 still need verification.
- Backend `9e5d13e`: the [drawing transaction foundation](https://drive.google.com/file/d/1Yv4l2SEqf467d8BHQ3DPpOW28ItzmGSS/view) is committed and tested, following metadata/history `2c4fe4c`. **25 final drawing/geometry checks passed**, zero failed/skipped. The broader **102-check** run passed before the final two geometry-file corrections; its source-specific evidence is retained separately. Eight additive tables, immutable page/version/pin history, current access checks and replay protection are implemented. **No drawing routes, real file processor, private gateway, journal/bootstrap coverage or native drawing sync is activated.** The startup migration registration is real; it has only been exercised in the isolated synthetic test database. The frozen image remains unchanged.
- Portal `a4bd706`: real delegation `84a5223`, private comments/replies/redaction `64894d7`, and v0.12 transport. Build and **94 tests passed**, zero failed/skipped. [Discussion report](https://drive.google.com/file/d/11LXFMkvvaBqb69SBxZjcZG5WFbnnCsZu/view). Actual new discussion captures and real staging D2 remain open.
- Matching isolated staging is **deployed disabled**: frozen image `91a53d9` is pushed and pinned, frozen portal `e250765` and its 14 assets/domain are deployed, adapter `ffc5f90` passes 29 tests/typecheck. [Exact remote deployment record](https://drive.google.com/file/d/11R4EIWUxMNC4OX560FI71VXacEb3OiqX/view). Newer working commits are deliberately outside those frozen candidates. No candidate secrets are installed; real startup/media/provider/browser acceptance remains open. Current HTTP probes meet Cloudflare1010; browser navigation was blocked by the client. The prepared two-bucket, 30-day storage credential still awaits the requested action-time confirmation.

Read the [dependency-ordered launch handover](https://drive.google.com/file/d/1iJJJ93iKC16Q71JmCSO2xr_TiC70bqKR/view) for the complete sequence and closing evidence.

**Next:** install/verify private staging credentials and startup, safely bind native stores/media/tasks to account scopes with explicit unclaimed legacy recovery, complete drawing/media/import graph and immutable outbox/pull. Then prove ordinary native capture → distinct second manager → scoped PIN Contractor link → evidence → accepted closure → native/fresh-device/report parity. Complete providers, company administration/test billing, reports/jobs and design acceptance where independent.

No production/recovery cutover, Git merge/push, App Store submission or live Team billing occurred. Credentials, raw recovery archives, database dumps and live link tokens stay outside Drive. Historical test counts below are not additive.

## Recovery checkpoint — 11 September 2026

Native source `c070d28` implements a verified device recovery copy: database/WAL-safe preservation, complete Documents media/files, SHA-256 manifest, fresh-directory restore and SwiftData graph reopen. Final staging tests at 17:46 UK: **176 passed, zero failed, five existing skips**. The simulator also created/reopened a synthetic device copy and exported its folder through Files. The old incomplete JSON action is now accurately named Export Project Summary.

Read [DATA-MIGRATION.md](https://drive.google.com/file/d/1ErZevbcsQd3-_phJ60JdBYHa2so3MHyy/view) and [IOS-RECOVERY-TESTS.json](https://drive.google.com/file/d/1t02TocvKqFUdRCiWuyqjF7zfht599r0T/view) for source hashes, recovery limits, UI observations and the remaining migration sequence. These are current-branch results, not a release or a claim of complete sync. Account-scoped stores/media/outbox and the ordinary native → second manager → Contractor link → accepted closure → fresh-device/report journey remain mandatory open gates.

Current parallel work continues on safe project discovery/comments, real manager delegation UI and an isolated Linux/staging candidate. Native account-bound subscription handling is implemented but still under test at this checkpoint. Existing native header/safe-area defects, older Contractor-link wording and mixed legacy visual treatments also remain on the acceptance list. No production cutover, merge, App Store submission or live Team billing has occurred.


Updated 11 September 2026. This is the active delivery plan, not a release approval. Owner: Daniel McCann. Engineering owner: the current build session. The latest Google Drive implementation brief is **v1.1**, modified 10 September 2026 04:59:30 UTC and refreshed for this continuation. The four-provider and usesnaglist.com decisions below supersede its older proposed hostname/provider scope.

## Executive assessment

**Do not release the unified platform yet.** Useful native and portal features are implemented, but the phone and browser do not yet share a complete, safely isolated project graph. The first priority is to protect local data and close that integration gap, not to publish the existing screens as a completed platform.

The public website and business email work. At **15:26 UTC on 11 September**, usesnaglist.com and staging-api.usesnaglist.com/health returned 200; the old production API api.snaglist.dev/health returned **530**; app.usesnaglist.com did not resolve. The deployed staging service is the older recovery image, not the current unified branch. Public health is not proof of current migrations, private media or customer login. See `PUBLIC-SERVICE-CHECKS.json`.

The current portal builds and its **59 tests pass, zero failures/skips**, re-run in this continuation. A fresh iOS staging build succeeded in Xcode at 16:26 UK time. The final safety-change test run succeeded at 16:49 UK time: **167 passed, zero failed, five existing skipped tests**. See `READINESS-MANIFEST.json`. Earlier native testing recorded 148 passes and 10 explicit skips; that remains dated evidence until a new source-specific result is recorded.

## Agreed scope and working rules

- iOS remains the offline capture app; the portal is an online manager companion. Keep Vapor/PostgreSQL, Cloudflare Containers, Neon, R2 and Resend.
- Implement **Google, Apple, Microsoft and email-link sign-in on app and web**, with explicit same-account linking and safe recovery. No email-based identity merging or inferred company membership.
- Contractors use free, no-account **Contractor links**. A contractor submits evidence; an authorised manager accepts closure. Submission, Awaiting review and Closed must remain distinct in UI, API and reports.
- Finish company administration for team plans: membership, invitations, roles, project access, ownership, branding, seat allocation, billing status and supportable lifecycle operations. Joining a company does not expose personal work.
- Preserve the approved supplied brand, native reskin/icon and accumulated portal design. D1/D2 are implementation gates; no extra design permission round is required.
- Existing device data must survive. Dan waived the old-server backup search, not preservation of remaining device copies. Ambiguous historical ownership must be reviewed; never assign all legacy records to the next login.
- Shared logged snags use revision-checked archive/restore with history and evidence retained. No direct contractor close or destructive deletion to hide work.
- All test data is synthetic. Email tests may reach Dan's authorised personal address only. No customer records, prices, purchases or live subscription activation are changed for testing.
- Proceed with routine implementation and isolated staging verification. Production routing, live commerce, merging and App Store submission require the completed candidate and concrete release disposition; none has occurred here.

## Preserved baseline

| Repository | Branch | HEAD at readiness start | Application checkpoint |
| --- | --- | --- | --- |
| `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink` | `feature/unified-platform` | `89bda2c` | `f9fb682781cfde7079a73c03169baa5c449f61c1` |
| `/Users/danielmccann/Desktop/Projects/SnagLinkBackend` | `feature/unified-platform` | `505b2f8` | `1abdb42` plus additive staging-domain configuration |
| `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal` | `feature/unified-portal` | `9c95ff7` | `ae5c7f28038ed02e10e26c2057ed84492ab42a29` |

Native and portal working trees were clean. Backend has unrelated untracked `.agent/`, `.agents/`, `.claude/`, `.cursor/` and `.env (1).staging.example`; leave them untouched. No branch reset, migration rollback or global tool cleanup is needed.

Public iOS was previously recorded as 1.2.0 and the local candidate as 2.0.0 (2). Those App Store values need current App Store Connect readback before choosing the release build number. Do not infer live version from local project settings.

## Outstanding work and completion evidence

| Priority / package | Actual current position | Work to complete | Evidence that closes the gate |
| --- | --- | --- | --- |
| **R0 — Reproducible candidate and matching staging** (WP-00/G0) | Adapter ffc5f90 and patched Wrangler 4.131.1 pass 29 tests/type checks. Backup/restore rehearsal passes 53 table fingerprints. Backend91a53d9 and portal e250765 are frozen build inputs; later branch changes are separate. Private buckets and disabled backend/portal deployments exist; new scoped credential/secrets, real startup/private media/provider/browser acceptance remain pending. | Record manifests; fix explicit staging configuration; build Linux image; verify image processing, migrations and readiness on isolated Neon/private R2; provision staging portal proxy/cookies. Preserve old recovery routes. | Exact source and image digest, database migration ledger, private-object access checks, startup/health/log-redaction evidence, reproducible deployment commands. |
| **R1 — Native data safety and complete sync** (WP-03/06) | Recovery, scope/path foundation and coordinator 339203a are tested. Shared drawing read paths are corrected. Live store/media/preferences remain global per environment; complete binding, explicit import and capture outbox are absent. Discovery, comments, project metadata and assignment history now have canonical coverage; canonical drawings/pages/annotations still do not. | Recoverable store/media backup and checksum manifest; account/environment-scoped stores, files, preferences, queues and cursors; stop late responses on account switch. Complete canonical fields, directories, drawings/pins, reference aliases and access discovery. Atomic immutable outbox; bounded snapshots/deltas; conflict/retry/rebootstrap/removed-access repair UI. | Fresh install and legacy upgrade/reopen; two-account isolation; interrupted import/upload/retry; missing media explicitly reported; complete fresh-device reconstruction with matching IDs/checksums/history; stale offline edits cannot overwrite accepted closure. |
| **R2 — Identity and account lifecycle** (WP-01) | Real local Google web sign-in/linking verified. Native Google implemented; real staging exchange unverified. Account-bound SDK subscription identity ac56cce passes native tests; receipt delivery/entitlement verification and remaining provider lifecycle remain open. | Complete all four providers using environment-specific registration; cancellation/replay/account-link collision/re-authentication; email login UI; sign-out/recovery/deletion/provider revocation; partition subscription identity. | Real provider round trips on iOS/web, same backend user across explicitly linked methods; rejected cross-account/stale callbacks; account deletion and sign-out revoke access; physical-device callbacks. |
| **R3 — Real manager delegation and record lifecycle** (WP-05/07) | Real register selection, assignment/deadline, prepare/activate Contractor links, selected media/PIN/expiry/revoke and archive/restore UI implemented at84a5223. Delegation tests pass in the latest94-test portal suite. Real new staging interactions/recording and full native-connected flow remain open. | Scoped selection; contractor and date changes; clear prepare/activate state; selected processed photo scope, PIN/expiry/revoke; revision-aware bulk failures; archive/restore and history. | Ordinary UI creates a Contractor link for exactly selected assigned work; reassignment/archive/revoke immediately remove access; failures retain intention/IDs/PIN safely; filters, selection, scroll and drafts survive. |
| **R4 — Complete shared close-out journey** (G1 + D1) | Browser → contractor → browser has been exercised locally; native capture and distinct second manager are missing. D1 continuous recording and current native/report comparison remain open. | User A captures on iPhone, imports/transfers explicitly to company; user B verifies invitation and acts as project Manager; contractor uploads after evidence; B accepts; A pulls and fresh device reconstructs; report agrees. | One continuous real workflow recording, browser/native captures and correlated revision/evidence records. No hand-written database seeding substitutes for capture/sync. |
| **R5 — Workbench, company admin and design completion** (WP-08/D2) | Polished core register/review/contractor system and a company administration slice exist. Several destinations and operational admin features remain unfinished. | Real overview/cross-project snags, saved views, contractors/trades, plans/pins, comments/activity, reports, company profile/branding/ownership, complete people/seat/billing UI. Correct remaining native older design/copy. | No dead navigation or placeholder success; staging populated/empty/long/error/permission/conflict states; Chrome/Safari and available other browsers; keyboard, 200% zoom, narrow/tablet layouts and large native text/VoiceOver; D2 rubric ≥4 in every dimension with defects addressed. |
| **R6 — Reports, notifications and durable operations** (WP-09) | Existing renderer/export and queued notification rows are present. Durable issued artifacts/jobs and measured delivery are absent. | Immutable report snapshot/revision manifest; accurate evidence beyond first 50 snags; durable leased jobs, retries/dead-letter visibility, authorised current recipients, cleanup/retention and opt-in reminders. | Correct downloadable issued report; delivery receipt and failure/retry evidence; process restart loses no committed job; revoked/archived media stays protected; ordinary support can diagnose failures. |
| **R7 — Entitlements and company plans in test mode** (WP-10/G4) | Individual StoreKit/RevenueCat foundations exist; cross-surface identity/refresh and company seats/checkout are unfinished. | Verify purchase/restore/account binding on server; company subscription and seats; signed lifecycle webhooks/reconciliation; owner/admin billing UI, concurrent capacity changes and duplicate subscription prevention. | StoreKit/RevenueCat/checkout sandbox receipts; no cached Pro transferred to another user; seat and cancellation/order/retry tests; contractors consume no seat; current commercial terms preserved. |
| **R8 — Operational and store release candidate** (WP-11/G2–G5) | Existing historical test/release docs are useful references; full release gates remain open. | Access/privacy/security audit, redacted event delivery, 5,000-snag performance measurements, backup/export/restore and image rollback drills; production secrets/origins, public privacy/support/delete-account info; signed device/archive, reviewer account/instructions, screenshots and App Store metadata. | Exact final builds/tests, real restore/rollback, supported-device acceptance, truthful analytics, clean release manifest, zero blocking known defects, complete iOS and portal release checklist. |

R0 infrastructure work and R2 provider setup can proceed alongside R1. R3 can use current contracts while R1 is completed. **R4 cannot pass before R0–R3 work together.** R5–R7 have independent implementation, but cannot bypass the integration, design or security gates. R8 gathers evidence continuously; the final disposition uses the exact candidate, not accumulated historical test counts.

## Seamless iOS/portal acceptance — owner clarification, 11 September

Dan explicitly confirmed that seamless portal/app integration is essential. This is a release requirement, not an optional later sync feature. Use `INTEGRATION-ACCEPTANCE.md` for the observable acceptance matrix. It covers ordinary capture, account identity, full project reconstruction, interrupted uploads, conflicts, permissions, revocation, archive/restore and report agreement. A one-way report upload or register-only snapshot cannot close R1/R4.

## This continuation's implementation checkpoint

- Native HTTP mutations no longer retry automatically on a timeout, lost connection or server error. GET/HEAD retries are bounded; cancellation and stale-session responses are rejected, including A → B → A.
- Personal snag review waits for the matching server acknowledgement before changing local status. Wrong snag/status, denied/conflicting/offline responses and changed local review state do not imply closure. Historical unowned approval payloads are retained for fresh review, not replayed against the current login.
- Local session restoration requires a complete token/UUID/activity set. Account creation accepts the backend UUID directly. Draining the legacy queue no longer claims full project sync or invents a last-sync time.
- The Cloudflare adapter now validates and forwards an explicitly enabled staging portal/private-media/link-key configuration and optional separate Google web/iOS clients. Recovery settings remain valid with the new gate off. Tests reject production origins/storage, incomplete settings and malformed capability keys. No deployed configuration or secrets changed.
- First iOS test run compiled the new tests and reported 161 passes, 3 failures, 5 existing skips. All three failures exposed an acknowledgement mapping mistake between persisted native `closed`/`rejected` and server `approved`/`sentBack`; that mistake is corrected. The corrected full run passed: **167 passed, zero failed, five existing skips**, 172 total. The only final warning is a pre-existing test-only retroactive Equatable conformance. Source checkpoints: native `861b2f0`, staging adapter `1585af1`; portal application source is unchanged. See `READINESS-MANIFEST.json` and `READINESS-CHECKPOINT.md`.
- These are safety prerequisites. Account-partitioned stores, backup/import, immutable revision-aware capture outbox and complete canonical pull remain open. A late-response check cannot cancel a write already committed by the server.

## Immediate execution order

1. Finish fresh baselines, record the security/privacy findings and create this plan in the existing knowledge bank.
2. Close concrete native safety defects found during the audit: server-confirmed review state, authenticated request boundaries and unsafe automatic write retries. These are prerequisites, not a substitute for account-partitioned stores and complete migration.
3. Implement recoverable local backup/partition/import and immutable outbox in small tested increments; extend the complete backend graph and discovery contracts where necessary.
4. Correct staging adapter omissions and establish the matching isolated service/portal. Complete the ordinary manager delegation flow while environment work is available.
5. Complete the real two-user/native close-out loop, then the rest of the workbench/admin, reports/jobs and test commerce using the established design system.
6. Run operational/store acceptance and produce the concrete release package. Keep the release blocked while any critical integrity, access, provider, billing or usability defect remains.

There is no defensible calendar go-live date yet: R1 and R4 are substantial incomplete integrations. Use passing evidence to set that date after the shared close-out journey and migration tests pass. A working domain or screenshot is not a schedule shortcut.

## Proposed rollout once the gates pass

1. Freeze exact candidate commits, schemas, assets and image digests; retain the rollback image and a verified isolated restore.
2. Install signed iOS candidate on physical devices and distribute a bounded TestFlight/pilot candidate; deploy the matching portal to a clearly designated pilot/staging origin with synthetic or explicitly authorised pilot data.
3. Complete founder walkthrough and representative builder/site-manager feedback; fix critical usability issues. Confirm provider production configuration and public legal/support pages.
4. Prepare the production migration, domain/proxy/AASA/CORS/cookie/sender changes as one reviewed runbook. Preserve old app routes and issued-link compatibility or show an honest unavailable/reshare journey where recovery is impossible.
5. Present a release disposition separately for iOS, portal and paid Team activation. The portal may have a reversible deployment; an App Store binary requires Apple review. Do not enable live Team billing merely because a sandbox passes.
6. After the specific launch decision, use the documented cutover/rollback, smoke-test sign-in/capture/share/review/report, and check error/delivery/sync health. Stop rollout on access leakage, missing data/evidence, false closure, payment mismatch or failing old-client compatibility.

## Inputs from Dan

No new product-design decision blocks local implementation. Reuse existing account access and prior authorisations. Ask only when a concrete dependent provider/action is ready:

- Apple Developer/App Store Connect sign-in if the existing session expires; production Google and Microsoft registration access when configuring exact callbacks.
- A physical iPhone and TestFlight/founder review at the integrated-candidate gate.
- Proposed Team tariff/legal commercial details before live activation, if not already settled in a newer controlling amendment. Build test mode first; do not invent live prices.
- A concrete production cutover, App Store submission and commercial activation decision after the candidate and evidence are reviewable.

No more mailbox approval or old-server backup search is needed. Passwords, signing keys, private tokens and customer records do not belong in this plan or Drive.

## Required maintained artifacts

Keep this plan, `NEXT-SESSION.md`, `PLATFORM-ACCEPTANCE.md` and the engineering README current after meaningful milestones. Maintain `DATA-MIGRATION.md`, `DEPLOYMENT-RUNBOOK.md`, `BILLING-READINESS.md`, `PORTAL-DESIGN.md`, `PORTAL-DESIGN-REVIEW.md`, exact test manifests and real captures/recording. Separate released-and-observed, current-branch-tested, implemented-unverified, in-progress and planned/absent states.

References: [implementation brief v1.1](https://drive.google.com/file/d/1d7H-EvCfdrc0GVPGnNEXHhJVeG-SbOlL/view), [current continuation](https://drive.google.com/file/d/1MoUSx6EI3ghXDWT4fW8kgjgGKZBSPzV9/view), [engineering index](https://drive.google.com/file/d/1m2RKSW72mxdlQAivT-ztWWlxL1YL4Dxb/view), [verified domain/email](https://drive.google.com/file/d/15Itk0Yvjib5FagJ22Gx4oRQiOIVwqq_y/view).
