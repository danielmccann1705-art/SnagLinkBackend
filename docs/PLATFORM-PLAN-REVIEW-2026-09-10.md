# Snaglist — review of the unified-platform plan

10 September 2026. Reviewed the full 24-section [implementation plan, revision 1.1](https://drive.google.com/file/d/1d7H-EvCfdrc0GVPGnNEXHhJVeG-SbOlL/view), modified 04:59 UTC, against the current iOS/backend working copies, the [9 September handover](https://drive.google.com/file/d/13s3JbrIVQ-Kug4P__gRZRhUZcK3JJwj_/view) and today's link/workflow fixes.

## Recommendation

**Use this plan as the platform direction, with a few execution amendments.** It correctly addresses the underlying product problem: the browser needs the same complete, authorised project that the phone captured. Retaining Vapor/PostgreSQL, making shared records authoritative, preserving no-account contractors, and requiring a real second-user close-out journey are the right choices for this codebase.

Section 12 is materially better than a generic instruction to make a clean dashboard. It specifies a practical register, generous evidence review, truthful states, preserved navigation context, real laptop widths and concrete task checks. I would keep that design direction and its rendered review gates. The approved native brand and actual contractor/report experience should determine the details.

The current request was to continue the existing fixes and give a view on the incoming plan. This review does not activate the document's instruction to implement the entire platform, approve its proposed prices, or claim that its product defaults are already released. No portal, company billing or new shared-data architecture was implemented in this slice.

## Amendments I recommend

### 1. Correct the workflow/media/jobs dependency order

WP-04 requires processed evidence and atomic notification events, but WP-05 introduces the media contract and WP-09 introduces durable jobs. Those foundations need to precede WP-04 acceptance. The current backend accepts optional photo URL strings and its notifications are not durable. Today's test-shutdown failure also demonstrated why request-independent jobs need explicit lifecycle ownership.

Split foundation from feature delivery:

- Add the minimal `MediaAsset` state/ownership contract, completion-evidence references, mutation receipts, change events and job/outbox tables during WP-03.
- Prove upload finalisation and processed-asset ownership before accepting evidence-required submissions in WP-04.
- Commit workflow, change event and notification job together in WP-04. Build scheduler delivery, digests and report jobs in WP-09 against those records.

This avoids temporary arbitrary-photo-URL or in-memory notification implementations that would immediately need replacement. It does not require a full reporting/reminder feature before the first close-out journey.

### 2. Version the new workflow instead of renaming stored values globally

The five-state target is clearer, and separating sent/opened/overdue from workflow is sensible. The current native `SnagStatus` nevertheless preserves `closed` as the raw value for `.approved` and `rejected` for `.sentBack`; legacy backend/UI/report aliases differ. Those values exist across stores, DTOs, filters and exports.

Keep the recovery candidate's persisted enum values stable. Introduce the v2 workflow and one explicit v1 translation boundary, with contract fixtures for native, Clip, old report uploads and server outputs. Migrate stored data deliberately. Preserve ambiguous historic closures as qualified records, as the plan already requires.

Today's fix conservatively displays legacy `complete`/`completed` as submitted and blocks generic PATCH changes into/out of review-controlled states. That is a safety boundary, **not** the complete future adapter. Before rollout, specify how the app records a manager's direct fix, retries a review, and reopens work through the new commands. Do not silently restore the direct contractor-close bypass to satisfy old UI wording.

### 3. Specify treatment of existing submissions without after photos

An after-photo requirement with an explicit manager waiver is a sound candidate default. It is a new product rule: today's completion route permits submissions without photos, and ordinary sharing is still snapshot-based.

Add a migration decision table covering an already-pending attempt with no photo, a missing original file, historical accepted work, and a new submission through an already-issued link. Preserve history; never invent an after photo or automatically label an old acceptance as evidence-verified. My proposed default is to keep historical decisions qualified, and require evidence or a newly recorded reviewer waiver when reviewing an old pending attempt under v2. Confirm the exact waiver experience in the first review screen.

### 4. Separate archive from the deletion users originally requested

Reversible archive is appropriate for shared history, but the current deletion fix is a removal/tombstone path that also cleans associated completion and media records. Reusing that method for the plan's shared archive would violate the new retention rule.

Create an explicit Archive command and UI for shared work; keep hard erasure as a separately authorised lifecycle operation. Preserve existing deletion receipts and never resurrect deleted work. Document what an archived item still retains and who can restore it. The plan's “agreed retention policy” and bounded offline company-access expiry are still unspecified operational values; put candidate defaults in the decision log and establish production values before real customer rollout.

### 5. Keep the full acceptance journey, with an earlier company-only smoke check

G1 is a good final integration proof: ordinary iOS capture, transfer, invitation, second manager, PIN link, after evidence, approval, report and second-device reconstruction. It combines several difficult migrations, however.

Add an earlier internal smoke milestone that creates a project directly inside the synthetic company and completes the two-user review cycle. Then run the exact G1 personal-to-company transfer and old-device migration case. This provides useful integration feedback sooner without weakening the final acceptance gate or replacing capture with hand-written database rows.

Keep the current release recovery candidate independently reproducible. Optional portal features should not delay recovery once its own identity, data, purchase and release gates pass. Conversely, a green backend suite cannot justify deploying the platform with unverified device migration.

### 6. Keep live Team charging behind its existing separate gate

The plan correctly treats Team pricing as test configuration. I would preserve this separation. Existing RevenueCat identities must be tested through the actual anonymous/identified combinations: RevenueCat's documented login behaviour can merge some combinations and leave others separate. [RevenueCat identity rules](https://www.revenuecat.com/docs/customers/identifying-customers)

Likewise, confirm the applicable App Store purchase arrangement before offering paid Team access in the shipping iOS app. Apple's multiplatform and enterprise provisions have different conditions; a Team label alone does not settle the route. This is a release/commerce dependency, not a reason to stop building and testing the entitlement resolver. [Apple App Review guidelines, 3.1.3](https://developer.apple.com/app-store/review/guidelines/#other-purchase-methods)

The plan's private download gateway is also the appropriate target for immediate access checks. R2 presigned URLs authorise their holders until expiry and may be reused during that period; switching to signed URLs alone would not establish immediate per-grant revocation. [Cloudflare R2 presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)

## Update the plan's technical baseline before implementation

The 9 September findings were correct for that dated source. The following now have local fixes and scoped evidence, and should be reused rather than rebuilt:

| Finding in the plan | Current delta |
| --- | --- |
| Native PIN publication broken | Candidate sends its existing verifier and demands server acknowledgement; backend format import/protection is endpoint-tested. Full native device path remains unverified. |
| Native revoke route absent | Token-based authenticated route implemented; repeated revoke and wrong-owner rejection tested; native failure retry improved. |
| Direct contractor closure | Public status route now permits start only; completion goes through review. Direct close attempts tested as rejected. |
| Report-only approval can regress | Latest scoped completion status overlays stale snapshots; approved report-only replay tested. Still no full canonical sync. |
| Competing decisions / stale generic updates | Project transaction locking and fresh-state checks added; competing completion decisions and stale PATCH tested. |
| Browser shows submission as completion | Labels, approved counts and action state corrected; rendered JavaScript logic checked. No new full browser/device acceptance claim. |

The combined final results are **46 distinct backend tests passed, zero failed or skipped**, plus isolated JavaScript/native acknowledgement checks. The iOS app build is blocked by Xcode cache permissions and simulator service access. These fixes are not deployed. Detailed scope, compatibility changes, source paths and test evidence are in the accompanying link-hardening addendum.

## Proposed start sequence for the platform campaign

1. Preserve a complete, reproducible recovery checkpoint and establish isolated native storage, account, media and provider configuration. Resolve the current Xcode verification blocker.
2. Build stable verified identities, browser sessions, memberships and central project permissions. Prepare the brand/component reference sheet alongside this.
3. Establish canonical parity, revision/idempotency and commit-safe sync, including the minimal evidence and durable-event foundations above.
4. Complete the authoritative workflow, private grant/media path and ordinary iOS upload/pull. Carry existing deletion and PIN tests into the new adapters.
5. Render and refine the register/detail/review samples, integrate the company smoke journey, then pass the full G1 transfer/migration journey.
6. Finish the workbench, reports, reminders, test commerce and measurement through the plan's existing gates. Keep “built”, “pilot-ready”, “ready to charge”, “released” and “validated” distinct.

No additional framework or backend replacement is justified by the current evidence. The main delivery risk is consistency across identities, devices, snapshots, grants and decisions. The plan addresses that risk; the amendments above make its dependency order and legacy behaviour more concrete.

## Published milestone references

- [Implementation addendum](https://drive.google.com/file/d/1od4c-_HYDnfhGSE3lk78p9qZgzmVh9dt/view)
- [Platform plan review](https://drive.google.com/file/d/1775_fVSrTRYj3zrjOvwuoL6ZkL_fbtb2/view)
- [Verification and source hashes](https://drive.google.com/file/d/1WpYVFUBxw3mWUt7DG7U3nV215DZawJWT/view)
