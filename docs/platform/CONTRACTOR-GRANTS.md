# Contractor links — current implementation checkpoint

11 September 2026. This is an incremental WP-05 candidate on `feature/unified-platform`, backend `fb42916` (preserving workflow source `7b4c8cd`). It is not deployed or a statement that WP-05, G1, D1 or D2 is complete. No production records, infrastructure routing, email recipients, subscriptions or prices were changed. The controlling Google Drive implementation brief was fetched again and confirmed identical to the local v1.1 copy.

## Behaviour and boundaries

A manager with current project **share** permission prepares an explicit selection of up to 100 logged snags and up to 500 before-photo assets. Completion-mode links must name an active contractor and every selected snag must be assigned to that contractor. Read-only and preview modes cannot change status or upload evidence. Empty selection is persisted as empty, never interpreted as the whole project.

Preparation has no public capability and expires after 24 hours. Activation rechecks current selection/assignment and that every requested photo is processed and attached. It saves an immutable issuance snapshot and creates a random 256-bit bearer capability. The public viewer projects current canonical fields; it does not use that snapshot as workflow authority. Default expiry is 30 days after activation, bounded to 1–90 days. This candidate does not yet meter the shared Free allowance at activation; that remains an explicit WP-10 integration requirement.

The original issuer's current share authority is checked on every recipient operation. Removal of that authority makes the old capability unavailable; another authorised manager must issue a new link. Any current manager with share permission can revoke or retrieve a link, regardless of original creator. Reassignment and archive permanently invalidate the affected `link_items` in the same transaction as the snag change. Reassigning back or restoring the snag never resurrects its old access. Full revocation is idempotent and deletes PIN sessions.

Before photos are explicitly selected. The public projection excludes company/client contact details, costs, internal comments, manager-only decision reasons and other submitters' evidence. It shows the five most recent submissions from the same grant, with send-back feedback for those submissions. Full history remains available to authorised managers. Drawings/plans are not yet shared by this new path; there is no all-project drawing fallback.

## Identity, PIN and retry safety

A recipient is recorded as **`actorKind: contractor_link`** with the grant UUID. This identifies capability use, not a verified individual. No user account is fabricated, and the issuing manager is never impersonated as the submitting actor. Manager acceptance remains attributed to the signed-in reviewer. The portal now labels the two types of submission accordingly.

The additive `CreateContractorGrants` migration retains all existing history. Completion attempts, private media, changes, activity and workflow outbox rows gain a separately constrained grant actor/creator column; exactly one real user or grant must be present. Review decisions continue to require a real internal user. Grant mutations have their own receipt table, keyed by grant and operation UUID.

Tokens are looked up by digest. To recover an activation response or let another authorised manager copy the original link, the token is stored encrypted with authenticated AES-GCM, bound to the grant UUID. Raw tokens do not enter mutation receipts, activity, issuance JSON or change feeds. `LINK_GRANT_TOKEN_KEY` is a separate 32-byte base64 key. `LINK_GRANT_TOKEN_PREVIOUS_KEY` allows retrieval and prepare retry verification during rotation; a rewrap operation and key-retirement procedure remain operational work. Do not rotate away a needed key before rewrapping/reissuing affected grants.

PINs accept 4–8 ASCII digits and use the server password hasher (bcrypt). The prepare receipt uses a keyed request fingerprint rather than a plain hash of the short PIN-bearing body, avoiding an offline PIN dictionary attack from a leaked receipt. Failed guesses commit even when the response is a failure: five guesses lock the grant for 15 minutes. Success issues a random, digest-stored, grant-specific Secure/HttpOnly/SameSite=Lax host cookie for at most two hours and never beyond grant expiry. At most 100 unexpired sessions are retained per grant.

Every public read, workflow action, allocation, binary upload and download uses the same grant/PIN/item checks. Writes require `X-Snaglist-Contractor: 1`; if a browser Origin is present it must equal `BASE_URL` exactly. Cross-origin requests receive no CORS permission for this header. Native clients may omit Origin but must send the header and retain the protected cookie. Contractor conflicts return a restricted error, never the internal manager snag DTO.

## Evidence and close-out

Uploads allocate a private asset against the grant, exact snag and completion intention. Submission accepts processed asset IDs only, not arbitrary remote URLs. It cannot steal another grant's or user's upload, reuse another intention's evidence, waive evidence or directly close a snag.

The existing image processor enforces real JPEG/PNG signatures, byte and dimension limits and fresh metadata-stripped JPEG renditions. Storage and processing occur outside workspace locks; current grant, PIN, assignment and uploader are checked again before readiness commits. Download fetches private bytes, checks integrity and rechecks scope before responding with `private, no-store`. Previously received bytes cannot be recalled. The historical public bucket is unchanged.

`CanonicalWorkflowService` performs the same atomic start/submit process for honest grant actors. Submit creates a pending attempt, attaches after evidence and changes the snag to `awaiting_review`; it does not close it. A current authorised manager can send back with feedback, receive a new evidence attempt, or accept the fix and close the snag. Revision conflicts retain the request rather than overwriting newer work. Snag, attempt/evidence, activity, sync changes, grant receipt and queued notification commit together. Notification delivery remains absent; queued does not mean sent.

## API and files

The executable contract is `docs/api/openapi.json` (candidate 0.8); the portal copy and 73 generated transport types are updated.

| Boundary | Implemented routes | Authority |
| --- | --- | --- |
| Manager | `GET /api/v2/projects/:projectId/links`, `POST .../prepare`, `GET .../:grantId`, `POST .../:grantId/activate`, `POST .../:grantId/revoke` | Current project share permission; normal bearer or cookie/Origin/CSRF auth |
| Recipient | `GET /api/v2/contractor/:token`, `POST .../verify-pin` | Active capability, issuer authority, PIN session after verification |
| Workflow | `POST .../snags/:snagId/workflow/start` and `/submit` | Completion mode and fixed current item scope; no accept/close route |
| Media | `POST .../snags/:snagId/media`, `PUT` / `GET .../media/:assetId/content` | Same grant, PIN, item and media scope, revalidated around storage |
| Existing browser | `GET /m/:slug`; existing `/link/:token` redirects | New `c2_` links use canonical viewer; historical tokens/slugs retain existing renderer |
| Native revoke adapters | Existing `POST /api/v1/magic-links/:token/revoke` and `DELETE /api/v1/magic-links/:id` | Signed-in sharing manager; token possession alone is insufficient |

Implementation: `Sources/App/Controllers/{LinkGrantController,ContractorGrantController,WebReportController,MagicLinkController}.swift`, `Services/{LinkGrantService,LinkGrantTokenService,CanonicalWorkflowService,PrivateMediaService,PlatformSnagService}.swift`, `DTOs/ContractorGrantDTO.swift`, `Migrations/CreateContractorGrants.swift`.

Rendering extends `WebReportRenderer` via `CanonicalContractorRenderer.swift`. `Resources/Contractor/` contains the approved IBM Plex fonts/OFL, supplied v2 wordmark copied unchanged from the portal, shared brand-token mapping, stylesheet and script. The SwiftPM resource manifest and Docker runtime copy include these assets. No new third-party application dependency was introduced.

## Verification and remaining work

Verification is recorded in [CONTRACTOR-LINK-REVIEW.md](https://drive.google.com/file/d/1rzo58sVN1MfFZ72OjKPsPzV9yz5xDOGa/view?usp=drivesdk); do not infer a gate pass from source presence. The final eight grant integration tests passed against a fresh, restricted-role, TLS Neon PostgreSQL 16 database. They cover protected operations and guess locks, scope/actor isolation, concurrent idempotent submission, another manager's acceptance, send-back/resubmission, permanent item removal, expiry/revocation, preview/read-only restrictions, missing-photo activation, encrypted retry retrieval, native revoke adapters and restricted conflicts. The report records the 234-pass core regression, the final eight-pass source fingerprint, actual contractor upload → manager acceptance → contractor closure, and its limits.

Still required before WP-05/G1/D2 or deployment can pass:

- Native prepare/activate/PIN client, ordinary capture/outbox/bootstrap migration and true iOS → manager → contractor → approval journey. Existing native/Clip readers receive `contractor_browser_required` for new grants rather than a legacy direct-status bypass. Associated-domain routing must keep new capability URLs in the supported browser until the native reader is compatible; device/Apple CDN behaviour is unverified. [Apple's associated-domain component/exclusion contract](https://developer.apple.com/documentation/bundleresources/applinks/details-swift.dictionary/components-swift.dictionary).
- Manager portal Add/share/prepare/retry interface and link management using these routes; activation currently has API evidence, not a completed manager UI.
- Explicit drawing/plan scope, approved contractor-visible comment model, all required media graph parity and a native publication manifest.
- Durable orphan-object cleanup and notification delivery/retry worker. Unattached uploads expire logically after 24 hours; physical deletion is not implemented by this slice.
- Private R2 provisioning/public-access-off proof, Linux container/resource/processing verification, real staging permissions/conflicts and responsive/keyboard/zoom acceptance. Local private files and synthetic Neon are not deployed staging.
- Commercial allowance reconciliation, Company/Team administration, seats/test commerce, and Google login on iOS/web remain in the authorised plan. No live billing or release activation.
