# Manager snag capture — implementation and verification

11 September 2026. Portal application **ae5c7f28038ed02e10e26c2057ed84492ab42a29**, branch `feature/unified-portal`. This is a completed incremental Add snag slice of WP-07, not a completed package, integrated native journey or deployed staging pass.

## User-visible result

Managers and other authorised editors can log a snag from the project register or its empty state. The form uses the established Plex typography, Marker action, Ink text and Stone surfaces. It captures the description, optional additional detail and location, priority, and a calendar deadline where the user's project permissions allow assignment. The server allocates the reference. A confirmed success opens the real snag detail and photo controls.

Closing the form or visiting another project preserves the draft in the current tab. Returning shows **Resume new snag**. Ordinary filters are preserved after saving; a notice explains when the new Open snag does not match the current filter. The new record is visible to authorised internal colleagues, but logging alone does not assign or share it with a contractor. No notification delivery is implied.

## Data and failure behaviour

`CreateSnagController` calls the existing authenticated API:

1. `GET /api/v2/projects/:projectId` rechecks current capabilities before every save attempt.
2. `POST /api/v2/projects/:projectId/snags` creates the canonical record with a stable client UUID and immutable operation UUID/payload.
3. `POST /api/v2/projects/:projectId/snags/:snagId/publish` logs it using the returned revision and a separate stable operation UUID.
4. The success state appears only after the response confirms publication and an active record. The register refreshes with its original query.

Creation and publication are two server transactions. A dropped response retains the exact request, record ID and operation ID; **Retry same snag** replays that request. Confirmed creation is never repeated just because publication is uncertain. **Check saved snag** reads the exact ID. A revision conflict requires the user to inspect the saved version and explicitly confirm it before publishing at a fresh revision. Archive, lost permission and expired sessions do not silently become success.

The controller rejects a mismatched response identity and invalid revisions. It compares UUIDs case-insensitively because the Swift service serialises them in uppercase. Duplicate clicks are suppressed. Account disposal and access quarantine abort pending work and prevent late publication or UI adoption.

Drafts and pending intentions are held by the account-owned project controller in memory, not browser storage. Reload/close and sign-out warn if work is pending. This is not a durable offline queue: after a tab is lost, a server-side unpublished draft may exist without this UI's recovery state. Cross-device draft discovery/recovery remains a sync/workbench requirement. Native SwiftData and existing report snapshots are not written by this slice.

## Changed files and reuse

Portal root: `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal`.

| File | Purpose |
| --- | --- |
| `src/data/createSnagController.ts` | Create/publish state machine, immutable retries, permission checks and explicit conflict recovery. |
| `src/components/AddSnag.tsx` | Shared modal/form, real saving/error/success states, retained-draft actions. |
| `src/ProjectRegister.tsx` | Populated/empty entry points, preserved filters, real detail/photo continuation. |
| `src/data/registerController.ts` | Account-owned draft lifetime, saved-record refresh and permission quarantine. |
| `src/WorkspaceHome.tsx` | Pending-work warnings and account-disposal cleanup. |
| `src/styles.css` | Small semantic layout additions using existing form, modal and button styles. |
| `tests/create-snag-controller.test.mjs` | Nine behaviour tests for publication, uncertainty, permissions, conflicts and late responses. |

No dependency, generated API contract, backend, native data model, billing or purchase change was needed. Existing backend implementation remains `1abdb42` under documentation HEAD `0dfc684`; relevant symbols are `PlatformSnagController.create/publish`, `PlatformSnagService` and `PlatformMutationService`. Backend root: `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`.

## Executed verification

`npm run build` passes contract consistency, TypeScript checking and the production bundle. `npm test` passes **59 tests, zero failures, zero skips**, including all nine new controller tests, at the exact committed source. `git diff --check` passes. Logs and source hashes accompany the evidence bundle.

The new tests cover:

- Separate creation/publication and canonical uppercase UUID responses.
- Lost create response with the identical payload on retry; lost publish response without duplicate creation.
- Current edit permission and manager-only deadlines; revocation during pending work.
- Conflict readback and explicit confirmation of a saved revision; archived-record refusal.
- Duplicate clicks, disposal, validation and mismatched response IDs.

Actual browser checks used ordinary UI, a real local Vapor host and isolated synthetic Neon database `snaglist_platform_test_0910222943_fc44`. Email was intercepted locally; no external recipient was contacted. Synthetic company Owner **Emma Hughes** logged two new records in **Willow Court · Plot 18**:

| Reference | Description | Actual persisted result |
| --- | --- | --- |
| SL5 | Kitchen window catches on the lower frame and will not latch | Open, High, published revision 2, unassigned, no due date. |
| SL6 | Loose screws at the hall door strike plate | Open, Medium, published revision 2, unassigned, due 18 September 2026. |

A read-only database check confirmed each record exactly once, the correct actor and location, no archive and no contractor assignment. The fresh browser reload showed SL6's stored description, date and actual photo-entry controls while retaining the **Closed** filter and its two matching rows. No new photo was attached and no Contractor link was issued for these records.

The same browser session verified draft retention through close → Projects → empty Plot 4 → back to Plot 18. The empty project displayed **Add the first snag** and remained empty. Automated date fill initially changed the widget without committing the controlled value; proper keyboard entry and blur retained 18 September across close/reopen, publication, database readback and reload. SL5's absent deadline is accurately recorded above; the automation issue is not presented as a confirmed product defect.

## Actual visual evidence

Captures live in `/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/portal-design/` and the downloadable evidence bundle. These are actual browser bytes, not reconstructed mockups.

| Capture | What it establishes |
| --- | --- |
| `manager-add-snag.jpg` | SL6 form with the committed deadline, real project and shared styles. Actual browser viewport 1280 × 720. |
| `manager-snag-logged.jpg` | Server-confirmed SL6 success with corrected action spacing and photo continuation. |
| `manager-add-retained.jpg` | Earlier SL5 draft retained after visiting a different project; no committed date. |
| `manager-add-empty.jpg` | Actual empty project and first-snag action. |
| `manager-add-mobile.jpg` | Actual connected app in a labelled 390 × 844 CSS-pixel frame, with long draft content and visible keyboard focus. |

The 390px form measured 372px client/scroll width; the 320px form measured 302px client/scroll width. Each outer app document's scroll width equalled its 390/320px viewport: no horizontal page or dialog overflow in these checks. The modal scrolls vertically, form actions remain keyboard-reachable, and Escape restores focus to **Resume new snag**. A narrow test draft was discarded without creating a third record. The success panel's cramped button spacing was found in a capture and corrected before final verification.

The viewport capability requested a larger desktop size, but the observed browser remained **1280 × 720**. The report uses the measured size. Responsive frames are not physical-device captures or browser zoom. No complete screen-reader/focus-cycle, 200% zoom, continuous workflow recording, native/report comparison, real staging D2 or G1 pass is claimed.

## Remaining work

Manager assignment, selected Contractor link preparation/activation, copy/retry/revocation and bulk work still need connected UI. The original snag-deletion feedback must remain an audited archive/restore workflow for shared records, with conflicts and old-link scope checked; do not implement a destructive browser-only delete. Native account-partitioned stores/media/outbox and full capture/sync/import, real native Google provider verification, complete company administration/seats/test commerce, drawings/reports/jobs and Linux/private-R2 staging remain separate unfinished packages. The core brand is established; substantial remaining native/portal usability work must not be waived by passing API tests.

No merge, push, production cutover, live billing or App Store upload/submission occurred.

## Review artifacts

[Download the complete evidence bundle](https://drive.google.com/file/d/17E0-i04geR9xnSt79Y6y0VK_ll0qe0N0/view). Actual [form](https://drive.google.com/file/d/1hOY_iJT3TIALE_I2wUP7Dwl5wGKJcJLh/view), [saved result](https://drive.google.com/file/d/1FxL4ps3_d0V8FZNxcxdrrRfUh5WWPRHs/view), [empty project](https://drive.google.com/file/d/1UBcGK2uEEljcwiCvpv7ic7IUd65hKGht/view) and [390px form](https://drive.google.com/file/d/1UdDPNx1rhUuDqSzgoNm7PnuklqPdDkPh/view) are also available individually. Continue with [NEXT-SESSION.md](https://drive.google.com/file/d/1MoUSx6EI3ghXDWT4fW8kgjgGKZBSPzV9/view).
