# Subscription identity and billing readiness

Updated 11 September 2026. Current branch implementation and evidence; not a paid activation or release approval.

## Executive status

Subscription identity is committed at `ac56cce`; the friendly errors and native-home corrections passed the 18:20 UK run (**186 passed, zero failed, five skips**). The later complete app checkpoint `6e751fa`, including revocation integration, passed the 19:25 UK run: **226 passed, zero failed, five existing skips** (231 total). Real StoreKit/RevenueCat sandbox purchase, restore, provider-account linking, backend entitlement enforcement and Team billing remain open release gates.

No product IDs, prices, trials or RevenueCat transfer settings were changed. No real purchase, restore, checkout, subscription activation or production account mutation was used in these tests. The staging app disables purchases.

## What changed

Repository `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink`, branch `feature/unified-platform`, subscription checkpoint `ac56cce`, subsequent app checkpoint `6e751fa`.

- `Snaglist/Services/SubscriptionIdentitySession.swift` owns a generation-bound RevenueCat identity and serial queue. Auth changes immediately remove the previous visible entitlement. SDK login/logout, customer information, purchases and restores wait in order and check the initiating generation and SDK identity before accepting results. A → B → A is a different generation.
- An in-flight purchase keeps the SDK's original account until it finishes. Changing accounts rejects its late UI result; it does not claim that an already-started purchase was cancelled or refunded. A transaction guard prevents overlapping purchase/restore requests within this app session.
- SDK CustomerInfo cached under the same app-user ID remains available for that owner offline. A global boolean no longer grants another account Pro. This local boundary does not change RevenueCat's backend alias/transfer rules.
- `SubscriptionManager.swift` publishes Anonymous or Free from actual auth identity even when purchases are disabled. It uses the owned entitlement's actual product identifier and expiry, replacing a placeholder plan description. Unattributed delegate payloads request an owned refresh instead of directly granting Pro.
- `AuthManager.notifyAuthStateChanged` changes the subscription identity synchronously; independent login/logout tasks were removed. `AppDelegate` connects the SDK only after configuration, so startup no longer assumes it is already configured.
- New `SnaglistTests/SubscriptionIdentityTests.swift` checks late reads, delayed logout, an in-flight purchase during account switch, immediate clearing, failed bind/retry, signed-out startup, the same anonymous user's owned cache and disabled-staging tier/allowance behaviour. Injected fakes exercise ordering; they are not receipts or measured customer purchases.

## Configuration retained

| Item | Current code |
| --- | --- |
| Monthly product | `com.snaglist.pro.monthly` |
| Annual product | `com.snaglist.pro.annual` |
| RevenueCat entitlement | `pro` |
| Anonymous allowance | 2 projects, 50 snags per project, 5 photos per snag; no Contractor links |
| Signed-in Free allowance | 3 projects, 50 snags per project, 5 photos per snag; 10 Contractor links per month |
| Pro | Existing unlimited project/snag/photo/link code allowances; existing gated exports/branding/plans/dashboard |

These are working-branch policy values, not an App Store/RevenueCat dashboard readback or proof of independent server enforcement. The local `.storekit` configuration contains test prices/trial assumptions; never publish these as current UK commercial terms. The current production prices, trial eligibility, transfer policy and entitlement reconciliation need provider readback and sandbox evidence. No company tariff is invented here.

## Evidence and limitations

- First run: `work/native-recovery/subscription-tests-1806.xcresult`, extracted `subscription-tests-1806.json`.
- Actual simulator Settings now displays Anonymous / 2 projects for the signed-out staging session; previously it displayed Free / 3 because purchases were disabled.
- Existing five skipped auth tests remain skipped, so this test count is not proof that live external login works.
- Independent backend entitlement verification, shared subscriber browser access, Google/Apple/Microsoft/email same-account linking, purchase restoration on another installation, account deletion/recovery and real receipt alias/transfer behaviour remain unverified by this slice.
- Account/environment-scoped project/media/outbox storage is separate incomplete work. A safe subscription cache does not make all local project data account-safe.

## Required completion sequence

1. Preserve the verified native checkpoints and existing commercial configuration; repeat relevant tests when implementation changes.
2. Configure the verified isolated candidate's provider audiences and receipt/webhook test environment. Confirm that native/web resolve the same backend UUID before testing entitlement sharing.
3. Exercise anonymous purchase → explicit account association, A/B switches, restore, expiry/cancellation/refund and a second device in StoreKit/RevenueCat sandbox. Read provider identity/receipts and backend state; never infer Pro from a button press.
4. Verify server-side enforcement and reconciliation, duplicate-subscription handling, signed lifecycle events, idempotent retry/out-of-order delivery and outage behaviour. Browser access must derive from the owning verified account's entitlement.
5. Complete Team sandbox billing, seat allocation and concurrent invitation/member changes; contractors consume no paid seat. Preserve personal subscriptions and company ownership boundaries.
6. Read back actual product availability, prices/trials, provider transfer settings and App Store metadata. Present the concrete commercial/release disposition before any live Team activation or submission.
