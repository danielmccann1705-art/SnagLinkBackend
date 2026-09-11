# Connected completion review — verification checkpoint

11 September 2026. Implemented and tested on local branches; not deployed or released. D1 remains in progress and D2/G1 have not passed.

## Source and automated results

- Backend `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`, `feature/unified-platform`, application source `7b4c8cd`, documentation checkpoint `81f9eb5` before this report.
- Portal `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal`, `feature/unified-portal`, `455c3e1` (review implementation `f763ae2` plus the observed conflict explanation fix).
- Native `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink`, `feature/unified-platform`, `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc`. No native code change or new full-build pass in this continuation.

| Evidence | Result | Scope |
| --- | --- | --- |
| `outputs/app-store-prep/backend-tests/platform-workflow-neon-fresh.{json,log}` | 8 passed, 0 failed/skipped; 101.626 seconds including build, 69.522 test seconds | Fresh PG16 migrations and all canonical workflow integration cases |
| `outputs/app-store-prep/backend-tests/platform-workflow-neon-full.{json,log}` | 226 passed, 0 failed/skipped; 398.632 seconds including build | Full current backend regression suite on a second fresh PG16 database |
| Backend source fingerprint | `5aed0bea8fb273da9cd11434ae6be6dd985a00cb48c27e5cc8d226b6dea5a191` | Sources and Tests, recorded by the runner |
| Portal checks at `455c3e1` | 31 passed, 0 failed/skipped; maintained API types and TypeScript pass; production build passes | Vite native config loader; JS 280.10 kB / 83.64 kB gzip |

The eight workflow cases verify processed owned after evidence; one immutable retry outcome; another authorised manager reviewing; competing decisions; send-back/resubmit/accept/reopen history; reasoned waiver/internal fix; stale/generic/legacy status guards; rollback; frozen history and a complete decision transaction across a 100-row delta-page boundary. Earlier database setup failures are superseded by these executed passes, not erased.

## Isolated database and interactive host

A new **Neon Free, PG16, London** project `snaglist-platform-tests` (`dawn-queen-24474678`, branch `br-empty-cake-zaqwvazt`) was created solely for synthetic tests. It is separate from recovered staging `nameless-star-27046161`. Provider-default branch label `production` inside this new project does not mean customer production. No existing records were copied, no plan upgraded and no recovered staging/production cutover occurred.

`work/unified-platform/run_neon_tests.py` is a separate runner pinned to this exact new endpoint. It verifies the default database is empty, creates explicitly named fresh test databases and distinct random-password roles, and verifies no superuser/create-database/create-role/replication rights or inherited memberships. Client TLS is in use. Neon proxies connections; client-side libpq TLS is checked rather than inferring encryption from the backend's `pg_stat_ssl` row. Credentials stay in mode-0600 task-private files outside Git, Drive and this evidence pack. The original local-only runner and DEBUG mailbox guards are unchanged.

The interactive review host is a task-local XCTest harness outside product source: `work/unified-platform/local-review/InteractiveReviewHarness.swift`, launched by `run_neon_review.py`. It uses the real application, database, session/CSRF routes and media/workflow commands. Its only HTTP-client substitute accepts synthetic identity emails to two exact `.test` recipients and saves the rendered message privately; all other outbound HTTP is rejected. No external email is delivered. This is not a real provider round trip or a passing automated test just because the interactive host starts.

Endpoints: local app `127.0.0.1:55486`, temporary Vite review `127.0.0.1:5177`, private intercepted mailbox `127.0.0.1:55487/mail`. The production portal build has no harness, credentials or fixtures. `seed_neon.py` creates all sample projects/snags/invitations/evidence/decisions through the ordinary v2 API. It does not perform native capture or use customer data.

The original Docker/OrbStack database and source-built local PostgreSQL remain unavailable on this host. Their failure no longer blocks backend integration tests. Native package/CoreSimulator access remains a separate unresolved build limitation.

## Actual browser observations

The current brand guide, supplied ZIP and already approved D1/native design work remain the visual source. The connected screen reuses Plex, Marker/Ink/Stone, the supplied wordmark, full before/after photos and explicit decision/history panels.

1. Requested a synthetic manager email through the real portal; followed the privately intercepted message; landing did not consume it; explicit confirmation created the normal browser-bound session. The UI resolved Emma Hughes and the synthetic Alder & Field Construction workspace.
2. Inspected a real 12-snag register and a separate empty project. The sample includes Open, In progress, Awaiting review, Changes requested and an explicitly accepted internal fix. Personal projects remained separate from company projects.
3. Opened SL1 from its detail panel into connected review. It displayed processed private before/after evidence, Attempt 2 awaiting review, Attempt 1 sent back, both completion notes and the recorded send-back reason. The synthetic second identity accepted a real invitation and submitted through the API; this is not a claim that two humans completed G1.
4. Selected Attempt 1: a clear earlier-submission banner appeared and acceptance was disabled. Returning to the current attempt restored the current decision target.
5. Entered a send-back reason, returned to the register/detail and reopened review: the unsent note remained. No status changed merely by editing or navigating.
6. Accepted Attempt 2 in one browser tab. The server-confirmed state became Closed and the acceptance note entered history. Reload retained closure and photos.
7. Submitted a stale send-back from another tab: the server returned a revision conflict and retained the unsent reason; it did not overwrite acceptance. Actual inspection found a useless re-review button when no pending attempt remained. `455c3e1` removes that action, explains the existing closure and leaves the note read-only/selectable. The corrected state was reinspected and captured.
8. Responsive DOM checks used the real authenticated page inside a development iframe at 320, 390, 768 and 1024 CSS pixels: document width equalled scroll width at each size. At 390, keyboard activation opened reopening, and the photo viewer opened and dismissed with Escape. No reopening was submitted in that check.

## Captures and limitations

Actual browser-returned JPEG bytes were saved unchanged; `.capture.json` files record SHA-256/byte count. No generated image or screenshot reconstruction was used for these captures. The construction photos themselves are the clearly synthetic development assets already recorded in PORTAL-DESIGN.md.

- `outputs/portal-design/connected-review-desktop.jpg`: pending review, paired evidence and two-attempt history.
- `outputs/portal-design/connected-review-accepted.jpg`: accepted closure persisted after reload.
- `outputs/portal-design/connected-review-conflict.jpg`: corrected stale-decision explanation and retained reason.
- `outputs/portal-design/connected-review-mobile.jpg`: actual app within a labelled 390×844 responsive inspection frame; a constrained browser layout, not a physical phone capture.
- `outputs/portal-design/connected-review-empty.jpg`: actual empty company project.

The in-app browser viewport override reported success but left pages 1280 pixels wide. The responsive iframe was used explicitly and verified by DOM widths; it does not establish device/browser-matrix or zoom acceptance. Native Preview access timed out, so screenshot bytes were saved through a nonce-protected loopback form into this task's output folder. This transport performs no capture or image manipulation itself.

Still open: fresh native/PDF comparison, continuous workflow recording, real provider mail/Google/Apple login, native capture and synchronisation, no-account canonical Contractor link flow, reviewer actor-name detail, bulk/Add/share and remaining workbench, private R2/Linux verification, device/zoom/permission/error matrix and G1/D2. A queued workflow event is not delivered notification. These passes do not mark a whole work package or release gate complete.

## Next dependencies

Complete canonical contractor grants, private scoped media and the live contractor renderer; then connect native account isolation/outbox/pull/import and execute the ordinary phone → second manager → contractor → approval → phone/report journey. Carry the newly requested Google sign-in and comprehensive team administration requirements through WP-01/02/08/10; see GOOGLE-SIGN-IN-TEAM-ADMIN.md. Preserve the current branches and build incrementally.
