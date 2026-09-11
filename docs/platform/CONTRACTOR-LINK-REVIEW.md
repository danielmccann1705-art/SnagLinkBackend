# Contractor link implementation and browser verification

11 September 2026. **Implemented and tested on local branches; not deployed. WP-05, G1, D1 and D2 remain incomplete.** This report supersedes earlier statements that canonical Contractor links were absent. It does not supersede the wider platform requirements.

## Source and environment

- Backend `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`, `feature/unified-platform`, application commit **fb42916**. Final Package/Sources/Tests SHA-256: `c623a8c033f6d12efe56cbaf3946fe093cabea4015cc39c284dd6ac9364b8488`.
- Portal `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal`, `feature/unified-portal`, application commit **de215b1**. Existing account/register/private-media/review work is preserved; this slice changes grant-actor attribution and the transport contract.
- Native `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink`, `feature/unified-platform`, unchanged at `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`. No new native build or capture/sync success is claimed.
- Workspace root below is `/Users/danielmccann/Documents/Codex/2026-09-06/her`.

Tests use the separately created Neon Free PostgreSQL 16 project `dawn-queen-24474678` in London, with fresh synthetic databases, TLS and restricted roles. The runner pins the endpoint, requires an empty default database and refuses a ninth retained test database. Eight now exist; clean up only specifically identified disposable test databases before creating more. Keep the interactive review database and its fixtures if further visual work needs them.

The interactive test host is actual Vapor on loopback `127.0.0.1:55486`, Vite on `127.0.0.1:5177`, and the synthetic review database `snaglist_platform_test_0910222943_fc44`. The test harness intercepts only the approved synthetic email identities; other outbound HTTP is rejected. Media uses private task-local files. This is neither the recovered Cloudflare staging Worker nor private R2 proof. No external email, customer record, production routing, price or entitlement was changed.

## What changed

The backend now implements fixed-scope prepare/activate/revoke, live Contractor link rendering, PIN sessions, private before/after media and evidence submission through the canonical review workflow. A recipient is an honest grant actor, not the issuing manager or a fabricated account. A contractor can start work and submit evidence; only an authorised internal reviewer can accept and close. See [CONTRACTOR-GRANTS.md](https://drive.google.com/file/d/13n1i2S_i9UtMp3QpADAowY_-0ypR6xi0/view?usp=drivesdk) for boundaries, endpoint map, configuration and file/symbol references.

The renderer uses the supplied v2 wordmark copied byte-for-byte from the portal, IBM Plex Sans, Plex Mono for snag references, Marker actions, Ink text and Stone/white surfaces. The final comparison caught an older wordmark in the initial dark header; that was removed and replaced by the current supplied identity on a light header. Fonts/OFL are copied unchanged. The licence's original trailing space is retained; application source whitespace checks pass.

Inspection also removed repetitive introductory copy, enlarged a single before photo, retained history expansion/focus through rerenders, replaced misleading native file-picker text with a clear Add after photos action and named attachment list, and replaced implementation language with plain upload/submission guidance. Content-derived asset URLs prevent stale script/style caches after an incremental deployment.

## Executed functional evidence

| Check | Observed result | Boundary |
| --- | --- | --- |
| Fresh schema and backend regression | **234 passed, 0 failed, 0 skipped**, `contractor-grants-neon-full` | Full core implementation before later static branding/copy/cache refinements; do not attribute this entire run to the final resource fingerprint |
| Final grant integration suite | **8 passed, 0 failed, 0 skipped**, `contractor-grants-v2-brand`; 101.071 seconds including build, 66.792 test seconds | Exact final source fingerprint above; fresh TLS/restricted-role PostgreSQL database |
| Portal contract/types/bundle | 73 generated types match contract; TypeScript and production build pass | Candidate contract 0.8: 53 paths, 66 operations, 73 schemas; implemented subset |
| Portal existing tests | **31 passed, 0 failed, 0 skipped** | Includes review controller, conflict, account-disposal and retained-operation tests; design-only cases remain simulated |
| Actual PIN entry | First load and deliberately expired synthetic PIN session show only the PIN gate; correct PIN restores scoped data | Session expiry was a scoped fixture change in the isolated database, not a product admin operation |
| Actual contractor upload | Selected a matching synthetic door-after PNG through the browser picker; note and file survived Back to snag → Check for updates → Continue; upload processed and attached on submit | No-account capability with ordinary protected routes; no browser auth bypass |
| Submission status | Contractor and manager both showed Awaiting review, before/after photos and the submitted note; no direct contractor close control | Uploaded report snapshots are not the state authority |
| Actual manager acceptance | Signed-in Emma Hughes opened the same project, reviewed both images, confirmed acceptance with a note; page changed to accepted closure and persisted after reload | One internal identity was used in this UI journey; second-manager authority is separately integration-tested |
| Return to contractor | Check for updates and reload showed Closed · accepted, accepted submission history and no further submission action | Current server state is projected through the existing fixed selection |
| Final attachment control | Add after photos opens the chooser; a non-submitted fixture file/name/note survive closing/reopening and refreshing; removal and keyboard clearing work | Drafts are in memory, not durable across a page reload/browser termination; unsaved drafts warn before leaving |
| Missing evidence | Submit without a photo shows a clear required-photo error | No empty/waived contractor close-out |
| Empty link | Explicit zero-item read-only link shows zero snags and no submit controls | Empty does not widen into whole-project access |
| Keyboard | Enter opens the enlarged photo; Escape closes it and focus returns to its trigger | Narrow interaction check, not a full assistive-technology audit |
| Responsive layout | Actual iframe document/body width equals 320, 390, 768 and 1024 CSS pixels respectively; no horizontal overflow | Synthetic browser layout checks, not physical iPhone/Safari or browser-zoom acceptance |

Eight focused cases also test committed PIN guess locks, session expiry, read/write/upload/download protection, cross-Origin/header rejection, actor isolation, concurrent idempotent submit, acceptance by another authorised manager, send-back and fresh resubmission, immutable issuance versus live state, cross-project/grant media rejection, permanent removal after reassignment/archive/restore, preview/read-only restrictions, expired/revoked links, encrypted retry retrieval, missing-photo activation, native revoke adapters and restricted conflict errors.

An earlier first run had one test assertion compare JSON object text in unstable key order. The assertion was corrected to compare canonical encoded data. Subsequent focused and full runs passed. Do not publish its raw failure log: it includes a synthetic capability in the assertion output. No product failure is inferred from that ordering assertion.

## Actual data-store check

The browser journey used synthetic `Willow Court · Plot 18`, project `687feaa2-8f70-56ab-8050-a3bb5e3ade76`, snag SL1 `094f2509-9c80-52c6-b301-a1b61fbcdf4c`. A read-only database inspection after acceptance confirmed:

- Exactly one accepted `completion_attempts` row with `actor_kind = contractor_link`, no user actor, and the expected grant actor.
- Exactly one `completion_evidence` association and one ready completion `media_assets` row owned by that grant.
- Exactly one accept `review_decisions` row attributed to a real internal user.
- Start, submit and accept entries in `workflow_outbox`, all still **ready/queued**, not delivered. Grant actors are retained for contractor events; acceptance records the user.

The readback is `outputs/portal-design/contractor-browser-integrity.json`. The seed manifest contains synthetic IDs only. Raw capabilities, PIN cookies, encryption keys and private email links are excluded from the published report and captures.

## Review artifacts

Actual browser captures, unchanged screenshot bytes, are under `outputs/portal-design/`, with matching `.capture.json` SHA/provenance files. The linked copies below are verified uploads in the knowledge bank’s engineering/evidence folder:

| File | Meaning |
| --- | --- |
| [contractor-pin.jpg](https://drive.google.com/file/d/1AmNR9MXm7zXaD0xZcwimr_aDo2D_nPP-/view?usp=drivesdk) | Final v2 PIN gate, no protected project data |
| [contractor-register-desktop.jpg](https://drive.google.com/file/d/1IwQQSxnVK1h4bE7-1JPi8zPiNQ2dinSb/view?usp=drivesdk) | Final populated Contractor link, current accepted/open/in-progress states |
| [contractor-submission.jpg](https://drive.google.com/file/d/1R3UKPxSv8F9s_YWmut7_LW8KSQSXkdme/view?usp=drivesdk) | Final evidence form and plain-language guidance |
| [contractor-manager-review.jpg](https://drive.google.com/file/d/1oPY7qdnqdxyGByCs47BOnL5UI4Un8zit/view?usp=drivesdk) | Real manager before/after review before acceptance |
| [contractor-accepted.jpg](https://drive.google.com/file/d/1Mll0KlJiV1uDtbGOgZQxG4BZdIuD-klJ/view?usp=drivesdk) | Final contractor accepted closure with retained evidence |
| [contractor-mobile.jpg](https://drive.google.com/file/d/1cXK33pEoajt1m1cXv7QVjstEPd3T9RE7/view?usp=drivesdk) | Final actual app in a labelled 390px iframe viewport |
| [contractor-empty.jpg](https://drive.google.com/file/d/1azwg9O_HilwyrX6Ah8d94R6vEDxANJ-g/view?usp=drivesdk) | Final explicit zero-selection read-only state |
| [contractor-awaiting-review.jpg](https://drive.google.com/file/d/1nB96PYfP1tYcOWes7B2SJ3cZtXlKT4I6/view?usp=drivesdk) | Functional trace captured during submission before the final wordmark correction; historical UI, not the current visual reference |

The review index separates current connected implementation evidence from earlier D1 design-only samples. No screenshot slideshow is labelled as a continuous workflow recording. D1's actual continuous recording and fresh native/report comparison remain open.

Test results: `outputs/app-store-prep/backend-tests/contractor-grants-neon-full.{json,log}`, `contractor-grants-v2-brand.{json,log}`. Intermediate focused results remain source-specific historical evidence. Portal check logs are `work/unified-platform/link-portal-{tests,types,build}.log`.

## Required next work

1. Complete native account partitioning, durable outbox/pull/import and full project/media graph. Restore a verified native build. Implement native prepare/activate/PIN handling and route new capabilities safely around the older installed-app reader; AASA/device behaviour is unverified.
2. Add manager Add/share/prepare/retry/link management against these exact contracts; retain context and explicit selection. Finish drawing/plan/pin graph and contractor-visible comment policy.
3. Complete durable notification delivery and orphan cleanup; verify Linux resource packaging/image processing and private R2 in isolated staging. The existing recovered staging deployment is unchanged.
4. Extend identity with the authorised Google iOS/web flows and explicit same-account linking; complete Company Owner/Admin membership/project access/branding, then seats and test commerce. Do not invent provider configuration or show a fixture as working Google authentication. No new prices or live billing activation.
5. Execute the real iOS → second manager → no-account contractor → approval → matching native/report G1 journey, then D2 permissions/conflicts/long-content/zoom/keyboard/device checks, recovery/rollback and remaining release gates. A working local browser loop is a prerequisite, not full acceptance.

No whole package or release is complete, and nothing in this checkpoint authorises production cutover, merge, deployment or App Store submission.
