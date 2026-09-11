# Platform acceptance — candidate, not complete

## Current checkpoint — 11 September 2026

Backend application `7b4c8cd` now passes **226 tests, zero failures/skips**, on a fresh isolated Neon PostgreSQL 16 database; all eight workflow cases also pass independently. Portal `455c3e1` builds and passes **31 tests**. Actual browser review verified private before/after evidence, historical attempts, retained notes, accepted closure after reload and stale competing-decision rejection. A discovered no-op conflict button was replaced with a clear explanation and readable retained note. Responsive iframe widths 320/390/768/1024 showed no horizontal overflow; this is not physical-device or zoom acceptance.

The new synthetic-only Neon Free test project is separate from recovered staging. A restricted, endpoint-pinned runner leaves the original local-only guards unchanged. Interactive email is intercepted locally; no external message or production deployment occurred. Native full-build, canonical Contractor links, full sync, D1 recording/native PDF, real G1/D2 and remaining work packages stay open.

Dan also explicitly added Google sign-in on iOS/web and comprehensive company administration for Team plans. See [Google sign-in and team administration scope](https://drive.google.com/file/d/1uM-7BkQd8ID5btihXfoL9BAe1uE1FvUg/view) and the [connected review verification report](https://drive.google.com/file/d/127OOiTiWcKU904asY9rjpOB8-3c5Bu1O/view) for evidence, runtime boundaries and next dependencies. Earlier database-unverified statements below describe the 10 September checkpoint and are superseded by this executed verification; no whole package or release gate is complete.

Backend `7b4c8cd` (workflow candidate; private-media base `6d742bf`); portal `f763ae2` (review candidate; private-photo base `1e8e387`); native `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`. Local branches only; no deployment/release.

## Package status

| Package/gate | Evidence / implemented scope | Still required |
| --- | --- | --- |
| WP-00 / G0 | Preserved reskin/recovery source and assets; source commits; fresh backend migrations/tests; isolated staging native configuration and compiled routing checks | Full native build/install and provider identities; exact deployed-image/migration reconciliation; real staging isolation proof |
| WP-01 | Verified identities; native auth/version checks; one-use browser challenges, secure sessions/CSRF; linked-email proof; recipient-verified invitation preview and confirmation UI | Provider/browser/native round trip, work-email native UI, Apple web/staging registration, recent reauthentication, account deletion/provider cleanup, historical email-only recovery |
| WP-02 | Workspace/membership/project grants; atomic verified invitations; role changes, member removal, last-owner protection and workspace ownership transfer; central project capability policy; revisioned grant removal/re-add and invitation-permission binding | Project transfer/lifecycle, global grant discovery, complete media/job/legacy-route access audit, two real internal identities sharing a project |
| WP-03 | Stable project/snag IDs, display allocation, revision conflicts, retry receipts, publish/archive/restore; immutable bounded register snapshots/deltas; workspace contractor/trade directory, normalised trade relationships, audited assignments; exact calendar deadlines and decimal costs; bounded server search/filter/sort/count pages; attached-media snapshots tested; new completion-history snapshots and complete transaction-group deltas pass the fresh PostgreSQL integration suite | Full project fields, folders/tags/units, media/drawings/pins/history graph, global grant discovery, durable snapshot/cursor cleanup, device/snapshot import contracts, old-reference alias migration |
| WP-04 | Recovery guards remain regression-tested. New canonical attempt/decision, evidence/waiver/internal fix/reopen, atomic history/change/outbox source compiles; **eight workflow tests and full regression suite passed** | Complete legacy/contractor adapters and historical reconciliation, real staging journey, notification delivery |
| WP-05 | PIN/revoke recovery guards preserved; internal-account private media allocation, processing, gateway and revisioned capture attachment tested locally; actual browser upload verified | Scoped prepare/activate contractor grants, current-data renderer, PIN-protected grant media, reassignment revocation, orphan cleanup, Linux processing and private R2 staging verification |
| WP-06 | Environment isolation foundation and source field audit | Account-scoped store/media/queues, durable immutable native operations, complete pull/merge, recoverable backup/import, offline conflict repair and ordinary capture integration |
| WP-07 / D1 / G1 | Core D1 design captures and real account/register/edit/photo UI locally exercised. Connected review/history/decision UI builds; controller tests pass; **connected review browser checks passed; D1/D2 remain open** | Recording/fresh native PDF; Add/share/bulk and remaining workbench; ordinary iOS → second manager → no-account contractor → acceptance → matching native/report proof |
| WP-08 / D2 | Core design language established; earlier narrow/zoom/keyboard sample checks retained | Remaining real workbench screens, preserved workflow context, full staging state/permission/conflict/responsive/accessibility inspection |
| WP-09 | Existing renderer/report/notification code preserved | Immutable reports and manifests, durable leased jobs, delivery/reminder retries and restart evidence |
| WP-10 / G4 | Existing personal purchase/usage verification code preserved | Verified cross-surface entitlement binding, test company billing/seats, webhook/reconciliation and commerce acceptance; no live price activation |
| WP-11 / G3–G5 | Existing event endpoint and optional authenticated-event fix regression-tested | Verified event delivery, operations/restore/rollback rehearsal, measured performance, security/privacy/device acceptance and release package |

No whole package or integrated gate is marked complete by these partial results. Account/environment isolation, complete graph bootstrap and integrated workflow are different requirements.

## Actual test results

**Backend locally verified private-media base:** `platform-private-media-full-final` — 218 passed, zero failed/skipped; 34.661 seconds including build, 27.988 seconds tests. `platform-private-media-preview` — seven passed, zero failed/skipped after adding the register photo preview. Results carry the source hash. Earlier fresh-schema 199, register 210 and mail 12 results remain historical evidence at their respective revisions.

**Current workflow backend:** `platform-workflow-current-build` compiles the app and all tests, 8.841 seconds, no tests executed. Eight new integration cases exist. `platform-workflow-compile` failed during database connection setup for seven media cases; `platform-workflow-postgres16` failed during setup for eight workflow cases. Those failures establish the environment limitation, not product correctness or eight workflow defects. No fresh-schema workflow migration success is claimed.

**Portal:** generated contract, TypeScript, production bundle and all **31 tests pass** at `f763ae2`. Six review-controller tests cover uncertainty, explicit evidence re-review after conflict, required reasons, account disposal/access removal, stale reads and pagination. The earlier four design workflow tests are still simulated-design tests. Build uses the documented Vite native config loader after the default config loader stalled on this host.

**Actual local browser:** real local email challenge/cookie session; 12 API-created snags; draft retention, saved location and two-tab revision conflict/explicit comparison; empty project inspection. Then actual native-picker photo upload through allocation/processing/attachment, persisted row thumbnail, enlargement and reload; snag stayed Open. Only one synthetic identity was used. No new connected reviewer interaction, two-distinct-user G1, native capture or real staging D2 pass is claimed.

**Native:** staging scheme/entitlement and compiled Foundation routing checks pass; source parsing passes. Full build remains blocked before compilation by package sandbox/CoreSimulator access. The visible old 133-pass Xcode report is dated 7 September and is not new evidence.

**Runtime:** original Docker PostgreSQL on 55439 does not answer usable database requests. OrbStack setup requires Dan's terms/privacy step. A task-local source-built PostgreSQL 16.15 cannot initialise because this sandbox denies shared memory. See WORKFLOW.md. No global reset or remote/customer test execution was attempted.

## Visual evidence and remaining checks

Retain `outputs/portal-design/index.html`, register/detail, evidence review, contractor phone, empty/filtered/200%-zoom and missing-media captures. The design source remains the supplied ZIP/current brand guide, not the superseded assistant pack.

`outputs/platform/account-unavailable-desktop.png` is an actual browser capture of the new account UI without a reachable local backend. Do not present it as successful sign-in or staging proof.

Actual connected local captures are `outputs/platform/connected-register-local.png` and `connected-register-conflict-local.png`. The full-page conflict capture exposed unnecessary space above the edit fields; the empty evidence placeholder is now hidden while editing to remove that gap. A later actual capture, `outputs/platform/connected-register-private-photo-local.png`, verifies private media on the connected register. The subsequent review workspace reuses the D1 layout but has not been rendered/inspected against its new backend; do not present it as visually accepted.

D1's continuous recording and fresh native PDF comparison remain open. `interrupted-walkthrough.mp4` is a still-image sequence, not a continuous workflow recording. D2 must be repeated against the real candidate, with no important visual/usability defects left unresolved.

## Next acceptance sequence

1. Complete canonical graph/reference/media prerequisites and workflow invariants while restoring native build access.
2. Finish identity lifecycle, account partitioning and recoverable import/outbox; retain ambiguous legacy ownership for explicit reconciliation.
3. Connect the established core portal screens and contractor renderer, then execute G1 with ordinary capture and two real internal identities.
4. Run adversarial integrity/access/migration checks (G2), finish the workbench/reports/jobs and real D2/G3 checks.
5. Verify test commerce, telemetry, restore/rollback and release readiness. Production cutover, live billing, merge and App Store submission remain separate actions.
