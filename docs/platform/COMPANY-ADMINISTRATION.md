# Company administration — implementation and review evidence

11 September 2026. This is a tested company-access slice of the authorised unified-platform v1.1 campaign, not a completed Team product or a release approval.

## Executive assessment

Company Owners and Admins can now use the manager portal to inspect colleagues, create/copy/revoke invitations, change company roles, remove company access, transfer ownership and assign individual project access. The interface uses the existing Snaglist design system and real authenticated API requests. Company roles and project roles remain separate; personal projects remain private; contractors retain their no-account Contractor link.

Source: backend **25065df** on `feature/unified-platform` (main administration slice **a783ed9**); portal **222866d** on `feature/unified-portal` (main screen **fc264cf**, verified-recipient and focus refinements **7920f9c/aeb9db4/222866d**). Native remains **c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc**. These are local branches, not pushed or deployed. Unrelated backend `.agent/`, `.agents/`, `.claude/`, `.cursor/` and `.env (1).staging.example` remain untouched and untracked.

**Verified:** 66 backend permission/canonical-mutation cases passed at a783ed9; after verified-email directory refinement, 16 relevant cases passed at exact final backend source. Portal types, contract generation, production build and all 43 tests pass. Actual browser use verified company role changes, invitation creation/copy/revocation, project assignment and retained drafts. Keyboard focus and four narrow layout widths were inspected and corrected.

**Not complete:** Google sign-in, company profile/report branding, seat allocation, billing, the full native sync/import journey, drawings/reports/jobs, deployed private storage/Linux verification and full G1/D1/D2 acceptance. No production record, live price, external email or release state changed in this slice. A dedicated Google Cloud project `snaglist-508309` was created for the separately required Google identity work; project creation is not provider-login acceptance.

## Capability and verification boundary

| Capability | Current implementation | Evidence and limitation |
| --- | --- | --- |
| Members | Owner/Admin-only, 50-row pages, literal name/verified-email search, active/removed filters | Backend paging, search and access checks pass; browser populated/filtered-empty views inspected. Email comes from `user_identities(provider=email)`, never mutable `users.email`. |
| Company role changes | Admin/Member; expected membership revision; owner cannot be demoted in this path | Browser changed synthetic Jamie Taylor Member → Admin → Member; server and audit readback. Competing revisions reject rather than overwrite. |
| Removal | Ends company membership and all explicit company-project grants; records retained | Server removal/replay tests pass. Browser confirmation inspected/cancelled to preserve the existing review colleague. This is not account deletion. |
| Ownership transfer | Owner-only, existing active recipient, expected company revision; former Owner becomes Admin | Existing integration tests pass. Control and explanatory confirmation implemented; a complete browser ownership transfer was not exercised. |
| Invitations | Create a named recipient invitation, copy its link, list/filter and revoke; seven-day expiry | Actual synthetic invitation created, copied and revoked. No email was sent. Verification/acceptance/membership/grants remain in existing tested services. |
| Project assignment | Search company projects; explicit Manager/Member/no access; retained choice and original revision | Actual browser assigned Jamie Taylor as Manager of Willow Court · Plot 18. Receipt-based retries and stale conflicts are controller/integration tested. Company Owner/Admin access is visibly inherited and cannot be hidden by removing an explicit project grant. |
| Activity | Paginated allowlist of membership, invitation, ownership and project-grant changes | Actual records identify Emma Hughes and the target; arbitrary detail, link capabilities and unrelated workspace data excluded. New project-grant events include resulting role; older events with no recorded role remain unknown. |
| Company profile, seats and billing | Not implemented by this slice | No plan, seat count, invoice or successful payment is simulated. Existing Team and entitlement work remains separate. |
| Google login | Required; provider preparation underway | Dedicated project created. No working Google sign-in button, provider-token exchange or native/web acceptance is claimed here. |

## Architecture and API

Backend root: `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`.

`Sources/App/Controllers/CompanyAdministrationController.swift` supplies four read models. Every read uses `PlatformAuthMiddleware`, a database transaction and `WorkspaceAccessService.requireCompany(admin: true)`. The common workspace lock and current membership are checked on the server. Personal workspaces are excluded. Results carry current workspace role/revision, bounded pages and `Cache-Control: no-store`.

| Endpoint | Purpose | Scope / paging |
| --- | --- | --- |
| `GET /api/v2/workspaces/:workspaceId/administration/members` | Company directory with optional verified email | Owner/Admin; `page`, literal `q`, `state=all/active/removed`; 50 rows |
| `GET /api/v2/workspaces/:workspaceId/invitations` | Invitation metadata and effective expiry | Owner/Admin; `page`, email `q`, status; 50 rows; no raw tokens, token hashes or recoverable URLs |
| `GET /api/v2/workspaces/:workspaceId/administration/members/:userId/projects` | All unarchived company projects and target's explicit grant/revision | Owner/Admin; active target membership required; `page`, project-name `q`; 50 rows |
| `GET /api/v2/workspaces/:workspaceId/administration/activity` | Filtered company administration audit | Owner/Admin; `page`; 50 rows |

Existing mutations are reused rather than reimplemented in a new permission system:

- `PATCH /api/v2/workspaces/:workspaceId/members/:userId`: role or null and `expectedRevision`.
- `POST /api/v2/workspaces/:workspaceId/owner`: target `userId`, expected company revision.
- `POST /api/v2/workspaces/:workspaceId/invitations`: email, company role, explicit project grants. The current invitation form creates an empty project selection; access is assigned after joining using the connected project-access panel.
- `DELETE /api/v2/invitations/:invitationId`: current administrator can revoke a pending invitation, including one created by another administrator.
- `POST /api/v2/projects/:projectId/members`: stable mutation/device IDs, target, role or null and expected grant revision. A receipt retry rechecks current actor authority. A removed grant retains its revision and cannot be recreated by stale revision-zero work.

Browser writes require the existing exact Origin and CSRF/session controls; native bearer handling is unchanged. `WorkspaceAccessService`, `WorkspaceInvitationService`, `ProjectAccessService` and `ProjectGrantService` remain the mutation authority. Invitation acceptance requires a verified recipient and an inviter who still has authority. Acceptance creates membership and selected grants atomically. Removing membership revokes project access and pending invitations for verified recipient identities; an accepted invitation cannot resurrect removed membership.

The existing `/members` array endpoint remains compatible. Its optional `verifiedEmail` is not populated from profile email; the new protected admin directory populates it from verified identity records. No migration or new Company model was introduced. Existing `Team`, `workspace_memberships`, `project_access`, `team_invites`, `invitation_project_grants`, `user_identities` and `workspace_activity` remain the stores.

The maintained OpenAPI candidate is **0.9.0**, with **56 paths, 70 operations and 81 generated transport types**. Backend `docs/api/openapi.json` and portal `contracts/openapi.json` match. These counts describe the implemented subset, not the complete platform specification.

## Portal implementation and interaction rules

Portal root: `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal`.

| File / symbol | Responsibility |
| --- | --- |
| `src/WorkspaceHome.tsx` | Company route and entry point; account-owned controller maps; preserves project/register contexts and destroys private state at sign-out |
| `src/CompanyAdministration.tsx` | Members, invitations, activity, role/removal/transfer confirmations and current identity explanations |
| `src/components/MemberProjectAccess.tsx` | Searchable project-role panel, inherited company access, pending/rejected changes and explicit retry controls |
| `src/data/companyController.ts` / `CompanyController` | Per-company tab/filter/page/draft state, read cancellation, permission-loss clearing, honest uncertain legacy writes |
| `src/data/memberProjectController.ts` / `MemberProjectController` | Per-recipient choices and original revisions; immutable project mutation receipts; no automatic conflict rebase |
| `src/components/ui.tsx` / `Modal` | Shared native HTML dialog; layout-effect cleanup closes the dialog and restores its opener's keyboard focus |
| `src/api/client.ts`, `src/api/types.ts`, `src/generated/apiTypes.ts` | Existing same-origin transport plus generated administration contracts |
| `src/styles.css` | Shared Marker/Ink/Stone/Plex treatment, stacked fields, administration rows and responsive layouts |

All company data, recipient choices, invitation capabilities and drafts stay in account-owned memory, not localStorage. Switching tabs, closing/reopening the project panel and ordinary in-app navigation retain intentions. Sign-out/access loss clears private records and invitation links. Reload/browser termination is not durable draft recovery; the existing before-unload protection warns about outstanding work.

Company membership/ownership/invitation writes predate mutation receipts. They are **never automatically retried** after an ambiguous result. The portal retains the invitation form, blocks further writes and asks for the relevant list to be refreshed. An unrelated tab read does not clear that uncertainty. If an invitation committed but its returned link was lost, revoke the pending invitation before creating a replacement; there is no hidden token-recovery claim.

Project-access writes use the existing durable receipts. The exact operation ID, requested role and original grant revision survive an interrupted request. An explicit retry returns the original result without a duplicate grant change. Definite rejection is shown separately; the user discards that rejected intention and reviews current access before choosing again. Merely refreshing the page does not rebase a stale choice.

## Visual and browser evidence

The supplied `Snaglistv2.zip` identity, portal wordmark and shared Plex tokens remain authoritative. No older assistant-created brand asset was introduced. Company roles use text labels rather than task-completion status colours.

Observed corrections:

- Stacked, full-width invitation fields keep recipient addresses readable.
- Verified email addresses distinguish colleagues with identical names; removal and ownership confirmations identify the recipient.
- Mobile headers remove repeated explanatory text, keep the primary action near the list and place search/status together. The permission explanation remains available below the records.
- Owner protection sits under the role, avoiding a broken action-column label.
- The project access panel fits the normal desktop viewport more efficiently and clearly explains inherited Owner/Admin access.
- Escape/Cancel originally dropped focus to the document body. Shared dialog cleanup now restores focus to `Manage Jamie Taylor` and `Project access for Jamie Taylor`; both were exercised in the browser. Moving from Manage to its removal step now focuses the close control instead of the removed button. A further nested-dialog defect made Escape on an enlarged photo close its underlying snag as well; cancellation now stops propagation. Browser recheck kept the snag open and focused `Enlarge original defect photo`, then closing the snag returned to its register reference.
- The 768px layout initially squeezed verified emails into fragmented table cells. Company administration switches to a stacked layout below 900px, with search and status beside one another when space permits. The corrected 768px view was rendered and inspected.

Actual captures are in `/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/portal-design/`: `company-members.jpg`, `company-invitation.jpg`, `company-project-access.jpg`, `company-activity.jpg`, `company-mobile.jpg`, `company-empty.jpg`, `company-removal.jpg` and `company-tablet.jpg`. Each saved capture has a companion `.capture.json` recording unchanged browser bytes, timestamp and SHA-256. Mobile and tablet captures are labelled **390px/768px iframe inspections**, not physical devices or native screenshots. A browser viewport override reported success without changing `innerWidth`; it was reset and was not counted as device verification. A final attempt to measure iframe document overflow returned unavailable document properties; it was not counted as a successful numerical overflow check. Final 320/390/768/1024 checks here mean visual inspection at those CSS frame widths, not a browser-zoom or device pass.

Actual synthetic journey: Emma Hughes opened Alder & Field Construction, changed Jamie Taylor's company role to Admin and back to Member, created/copied/revoked `rachel.site@example.test`, and assigned Jamie as Manager of Willow Court · Plot 18. Invitation and project-role drafts survived normal panel/tab navigation. Company role/removal policy tests cover actions not committed in the browser. No customer records or external recipients were used. An old controller instance briefly failed during development hot replacement after its class API changed; a fresh page instance loaded correctly. That development incident is not a production build pass or a hidden data repair.

## Tests and limitations

| Run | Result | Source / environment |
| --- | --- | --- |
| `company-access-audit-final` | **66 passed, 0 failed, 0 skipped**, 217.120s including build | a783ed9; source SHA `f5cb13508082269c075731f04b8af7d27e76fcc1aba1eed815c2d3cca07b7dfb`; company administration, workspace integration, policy and canonical-mutation suites |
| `company-verified-directory` | **16 passed, 0 failed, 0 skipped**, 61.694s including build | Exact final backend 25065df; source SHA `119908f744e602a28a3b3bc383a6e9c07fca9e830cd62cc410917885d685eee0` |
| Portal | **43 passed, 0 failed**; generated types, TypeScript and production build pass | 222866d; `company-portal-final-tests.log` and `company-portal-final-build.log` in the task's `work/unified-platform` folder |

Backend tests used the existing **isolated synthetic** Neon test database `snaglist_platform_test_0911074529_fa3f`, project `dawn-queen-24474678`, with TLS and a restricted role. This run **did not create a fresh database**. Fixtures have unique IDs; the interactive review database is separate. Eight disposable databases are retained; no database or customer backup was dropped. Exact source fingerprints cover Package.swift, Sources and Tests; documentation-only commits do not change them.

Important boundaries:

- The 66-case run preceded the small verified-email directory refinement; the subsequent 16 cases cover that final change. Do not describe 66 as an exact-final full-suite pass. Earlier 234-case Contractor core and final eight-case brand results remain separate dated evidence.
- Search/paging, cross-company/personal isolation, revoked authority, immutable request retry and conflict behaviour have automated evidence. Current browser checks cover synthetic populated/empty states, real actions, keyboard return and visual inspection at 320/390/768/1024 CSS widths. They do not establish full D2, assistive-technology, zoom, every failure state or measured performance.
- Offset pages can move under concurrent changes. Current profile names and company names are joined for display; this is not an immutable historical copy of every name. Old project-grant events do not retroactively gain a role value.
- Pending invitations can become unusable when their issuer loses authority or offered project-grant revisions change. The server enforces this at preview/acceptance; the admin list's pending label is not a guarantee of successful future acceptance.
- Google login, billing/seats, company profile branding, invitation email delivery/resend and complete release operations remain open. A copy-link flow is the implemented invitation mechanism. Google Auth Platform branding was created under dedicated project `snaglist-508309` with an external **Testing** audience; the client list remained empty at this checkpoint. A local web-client form was prepared but creation was not confirmed. No production publication or working Google sign-in is claimed. Basic identity-only consent and an accurate public privacy disclosure remain required under [Google's API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy).
- Native remains unbuilt at the latest source. On 11 September Xcode 26.2 was present, but the command-line simulator service failed and Xcode UI automation timed out. No global caches or simulator state were reset. Dan was asked to save work and reopen Xcode. The historical 7 September test report is not a new native result.

## Next dependencies

1. Restore and verify the native build, complete account-partitioned SwiftData/import/outbox/pull and the full canonical graph. Preserve existing reskin, data and purchase identities.
2. Complete Google provider setup and explicit same-account identity linking on iOS/web; verify cancellation, replay/audience/issuer/nonce failures, account recovery/deletion and purchase restoration. Project/client creation alone does not pass this gate.
3. Finish manager publication/share/link-management and the ordinary native → second manager → no-account contractor → accepted closure → native/report journey. Preserve the current fixed Contractor link boundaries.
4. Extend this company system with profile/report branding, test-mode seats/billing and verified entitlement reconciliation. No live Team price or billing activation is authorised by these UI controls.
5. Complete drawings/reports/durable jobs, private R2/Linux staging and G1/D1/D2 evidence, including a real workflow recording and native/report comparison. Then perform the remaining operational and App Store readiness gates. Do not merge, deploy production or submit a release from this checkpoint.

## Google Drive evidence

These are the actual saved browser captures described above, uploaded to the existing engineering evidence folder.

- [company-members.jpg](https://drive.google.com/file/d/1QeoWZeUyk1z1m5TP1fKK-ayzfWQlrsba/view?usp=drivesdk)
- [company-invitation.jpg](https://drive.google.com/file/d/1KPq_VLk2wjWjaJ3HSm3_Yp9C4HD1FQ4B/view?usp=drivesdk)
- [company-project-access.jpg](https://drive.google.com/file/d/151lUc8CcUcxRYPkZhIDPpeoJ1Pjxr3FY/view?usp=drivesdk)
- [company-activity.jpg](https://drive.google.com/file/d/1VkKPEVqKsB0sHH1_fjZ3UpGqibO6JyBF/view?usp=drivesdk)
- [company-mobile.jpg](https://drive.google.com/file/d/17oHzp1J_PSnR_X98gjZQcIaS20JMngvf/view?usp=drivesdk)
- [company-empty.jpg](https://drive.google.com/file/d/1mC80fXApaXCdMBETysBIJFlgadH0fjQ8/view?usp=drivesdk)
- [company-removal.jpg](https://drive.google.com/file/d/14u6azsTUhdh_awmnj1gl_QkhE53WjVce/view?usp=drivesdk)
- [company-tablet.jpg](https://drive.google.com/file/d/1W_U5K0hLCKLF0KE0J0xB0lTaAce2ZFPt/view?usp=drivesdk)

[Download the complete evidence bundle](https://drive.google.com/file/d/1PQ2ckYl7aamQP0EBJjV0oEetTN91Q1va/view?usp=drivesdk): eight unchanged captures and SHA-256 metadata, source-specific backend results, final portal test/build logs and the report.
