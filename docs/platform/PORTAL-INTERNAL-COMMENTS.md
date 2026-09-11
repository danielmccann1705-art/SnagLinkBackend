# R5 portal internal discussion — implementation handover

Prepared 11 September 2026. Status: **implemented, reviewed and committed locally; unreleased; actual browser visual review and real-staging D2 remain open**.

## Assessment

The existing snag detail now exposes the canonical backend's internal discussion. It supports chronological team comments, one-level replies, and audited removal without introducing a new feed or altering Contractor links. The implementation uses the existing Marker/Ink/Stone and IBM Plex system, ordinary accessible form controls and the current register lifecycle. No backend schema, generated contract, staging configuration, price or production record was changed.

The local automated suite and build pass. The actual component has an isolated synthetic review artifact, but it has **not** been inspected in a rendered browser during this task. The browser tool explicitly blocked that artifact's URL, and no alternative browser-control method was attempted.

## Exact source context and ownership

Portal: `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal`, branch `feature/unified-portal`, base `e2507654300592329f018031dd3f66c0feec2aa6`; discussion checkpoint `64894d7`. Root reviewed and committed the nine files. A separate subsequent transport-only refresh at `a4bd706` adopts backend `2c4fe4c` OpenAPI v0.12 (97 schemas); the build and all 94 tests pass again. The older frozen staging export remains e250765 and is not updated implicitly. Backend comments were inspected at the parent-supplied `91a53d9` source context; this task did not change backend source.

At the discussion-only checkpoint, generated API types were unchanged. Their then-maintained-contract SHA-256 was `5e40478763b130216c85dd765bf4f9cd80ec4dd17fa3a293b3532b30ca9291be`. Current `check:api` passes.

| File relative to portal root | Change |
| --- | --- |
| `src/components/InternalComments.tsx` (new) | Actual detail discussion, empty/loading/error/read-only states, reply drafts, removal reason and retry/conflict UI. |
| `src/data/commentsController.ts` (new) | Owned private in-memory state, pagination, request identity, permissions, cancellation, quarantine and acknowledgements. |
| `tests/comments-controller.test.mjs` (new) | 20 focused tests, including real owning-register denial propagation and same-origin API wrapper checks. |
| `src/api/client.ts` | Typed wrappers for existing comments list, create and redact routes. |
| `src/api/types.ts` | Four aliases to existing generated comment command/page/response types. |
| `src/data/registerController.ts` | Owns discussion controller; central access-denial quarantine and read cancellation. |
| `src/ProjectRegister.tsx` | Discussion after the existing detail form; includes comment intentions in draft warnings. |
| `src/WorkspaceHome.tsx` | Includes discussion in workspace unload/sign-out warning and all existing controller disposal paths. |
| `src/styles.css` | Shared-token reading hierarchy, reply indentation, accessible controls and narrow-screen wrapping. |

No native source is owned by this task. No generated API file was edited. The final build used a separate scratch output directory. An initial default local build updated ignored `SnaglistPortal/dist` before root clarified the frozen staging snapshot boundary; root was informed. Subsequent builds and this final verification did not touch that directory. This report does not assert that the initial ignored directory still represents the frozen snapshot; root should continue to use its immutable staging source artifact.

## Backend contract and scope

Read these actual source files in `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`:

- `Sources/App/Controllers/ProjectCommentController.swift`
- `Sources/App/Services/ProjectCommentService.swift`
- `Sources/App/Services/ProjectAccessPolicy.swift`

| Endpoint suffix under `/api/v2/projects/:projectId/snags/:snagId` | Authentication and behaviour |
| --- | --- |
| `GET /comments?after=<UUID>` | Authenticated manager session; project `read`; platform-managed project; verifies the snag/project relationship. Ascending `(created_at,id)`, 100 per page and next cursor. |
| `POST /comments` | Project `edit`; immutable mutation operation/device IDs and client comment ID; trimmed body 1–10,000 Unicode scalars; optional same-snag, unredacted top-level parent. New comments on archived snags are rejected. An existing original mutation can still replay to resolve its receipt. |
| `POST /comments/:commentId/redact` | Project `edit` plus original author or `archive` capability. Requires expected revision and a 1–500-scalar reason. Revision conflicts are explicit. Response is a tombstone; backend retains audit information. |

API wrappers use the existing same-origin session cookie, CSRF header for writes, no-store requests and abort signals. There is no direct public/Contractor-link comments request. The UI's permission helper mirrors the disclosed backend conditions; the server remains authoritative.

This API is snag-scoped. Project-wide discussion, comment editing, mentions/notifications and comment attachments are absent from this slice because the inspected contract does not provide them. The UI does not suggest those features exist.

## Behaviour and privacy safeguards

- Register filters, selection, scroll and ordinary snag drafts continue to be owned by the existing register. Comment and reply drafts are separately keyed by snag and parent and remain in memory while navigating that authenticated workspace.
- Drafts are not stored in browser persistence. Sign-out/account replacement disposes this private controller. There is no draft recovery across browser closure; the existing workspace unload warning now includes comment work.
- First send freezes the exact trimmed body, parent, comment ID and mutation metadata. Timeouts, server errors and mismatched acknowledgements retain that same command. The original draft cannot be edited or silently discarded while its outcome is unknown.
- Successful create acknowledgement must match comment ID, project, snag, internal visibility, authenticated author, original parent and original trimmed body. A valid later redacted tombstone can acknowledge the original create without restoring its body.
- One reply level is allowed. The UI keeps a reply draft when its parent is removed. It blocks a new reply to that parent but permits a retry of an already uncertain original mutation, matching backend receipt semantics.
- Refresh re-reads already inspected pagination ranges, deduplicates comments and guards repeated cursors. It preserves known tombstones so an old page cannot revive removed text. A single refresh has a 32-page safety bound; further records remain available through Load more comments.
- Removal requires explicit reason entry. Its exact reason, expected revision and operation ID survive uncertain retries. A revision conflict requires refresh and explicit acceptance of the newer revision before a new mutation is prepared. Removed body text is hidden and cannot be revived by delayed reads/create receipts.
- Abort/epoch checks prevent account replacement, disposal or permission quarantine from accepting late responses. All `401/403/404/410` comment denials now propagate through `Register.denied`, clearing cached register rows, details and selection as well as discussion content. Owned intentions remain quarantined until verified same-account access is restored. An obscured `404` cannot leave a previously visible project register on screen.
- Loading failures retain ordinary drafts and use honest error copy; no placeholder success. UI text explicitly says **Project team only** and that comments are never included in **Contractor links**. No completion state, approval right or Contractor-link close-out rule was changed.

## Design/source review

The component sits beneath the existing detail metadata/editing form, keeping evidence and snag information ahead of discussion. It uses the established shared tokens and font assets, chronological author/date hierarchy, 16px reading text and 44px minimum controls. Replies have one restrained indentation level. Removal is an inline reason form rather than a second modal within the compact detail modal. The composer permits selection/copy of locked original text, and status/error messages use live-region semantics. Text and names render through React text nodes.

The source was checked for narrow-width wrapping, long strings, role-based controls, empty/read-only/archived states, nested-form avoidance and retained drafts. These are implementation/source observations, **not a substitute for actual browser layout, keyboard, zoom or responsive verification**.

## Executed verification

- `npm test`: **94 passed, 0 failed, 0 skipped**. Includes 20 new comments tests and all 74 existing portal tests.
- `npm run build -- --outDir ../work/readiness/comments-final-dist`: **passed** maintained API parity, TypeScript and Vite production build.
- `git diff --check`: passed.
- Actual-component fixture rebundled from final source using the repository's installed esbuild.

Focused evidence includes immutable retry/archived receipt recovery; independent reply and snag drafts; Unicode bounds; member/viewer/manager removal rights; nested/removed-parent guards; pagination and tombstone preservation; conflict re-review; account/permission late-response rejection; all four access-denial statuses; obscured denial clearing the owning register; response ID/author/body/parent mismatch protection; valid later-tombstone acknowledgement; original-reply retry after parent removal; missing-removal-tombstone uncertainty; no managed API access from an unmanaged project; same-origin endpoint, CSRF, payload and no-store assertions.

Logs:

- [Test log](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/portal-comments-tests.log)
- [Build log](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/portal-comments-build.log)

The Vite warning that the scratch outDir is outside the project and will not be emptied is expected. No broad cleanup was run.

## Review artifact and actual browser limitation

[Actual-component synthetic review](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/comments-review/index.html) imports the real component and controller. It includes Willow Mews / Plot 12 / entrance-door discussion, a reply and a tombstone, plus populated/empty/viewer/archived selectors and simulated connection loss. It uses fake in-memory transport only; no real API calls, records, cookies or live credentials. It is a component sample, not a full-register or real-staging acceptance record.

CUA browser inventory succeeded. Creating a dedicated Chrome tab at that local artifact was rejected with the following tool wording:

> Browser Use rejected this action due to browser security policy. Reason: The browser URL policy blocks this action. Browser use cannot visit the requested page because its URL is blocked by the Browser use URL policy. The agent must not attempt to achieve the same outcome via workaround, indirect execution, raw CDP or browser commands, alternate browser surfaces, or policy circumvention. Proceed only with a materially safer alternative that does not require this blocked browser action; if none exists, stop and request user input.

This was an explicit **browser URL policy rejection**, not an automatic approval-review rejection and not a bridge timeout. No workaround, alternate browser-control stack or further blocked-URL attempt was made. **There are no new actual browser screenshots or workflow recordings from this slice.**

## Remaining acceptance work / handoff

1. Root reviews and commits the bounded portal files. Keep the current immutable staging candidate separate until this newer source is deliberately promoted.
2. In a permitted browser environment, inspect the real register and actual discussion component at desktop, narrow mobile and zoom; exercise keyboard focus, long content, empty/read-only/archived/error states, reply draft navigation and reason-entry readability.
3. Against isolated real staging, verify session identity and CSRF, create/reply/removal with the actual backend, pagination, interrupted-send replay, permission removal including obscured 404, mixed-client redaction and stale response handling. Compare discussion changes reaching native once native consumes the canonical comments graph.
4. Confirm internal comments remain absent from actual Contractor-link views and report exports with end-to-end acceptance evidence. No report or Contractor-link renderer changed in this task.
5. Capture actual screenshots and workflow recording, fix any material visual/usability defects, then update D2 and go-live status. Do not label the portal or unified iOS journey complete from this local suite alone.

References: portal `docs/GO-LIVE-PLAN.md`, `INTEGRATION-ACCEPTANCE.md`, the established `outputs/platform/PORTAL-DESIGN.md` and `PORTAL-DESIGN-REVIEW.md`, and the controlling implementation brief v1.1 already refreshed by root. The root session owns those shared records and Google Drive updates; this task did not edit them.
