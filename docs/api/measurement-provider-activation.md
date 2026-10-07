# Measurement provider activation

This package is inert by default. `productAnalyticsEnabled`, `crossCompanyAdsEnabled`,
`linkedInConversionsEnabled`, and `adMeasurementEnabled` all resolve to `false` unless
an environment value or database override explicitly enables them. Applying the
migrations or deploying the image does not activate a provider.

## RevenueCat lifecycle webhook

Create one RevenueCat webhook only after this backend route is deployed and its
isolated secret has been installed:

- URL: `https://<backend-host>/api/v2/measurement/webhooks/revenuecat`
- Environment: **Sandbox only** for the first integration run
- App: the single Snaglist iOS app
- Event filters: **Initial Purchase**, **Renewal**, **Cancellation**, **Expiration**,
  and **Refund Reversed** only
- Authorization header: `Bearer <high-entropy webhook-only secret>`

Set the same complete header value in `REVENUECAT_WEBHOOK_AUTHORIZATION` and set the
RevenueCat app identifier in `REVENUECAT_APP_ID`. Do not reuse the RevenueCat secret
API key used for customer deletion. The endpoint accepts at most 64 KiB, validates
the authorization value in constant time, and accepts only the App Store products
and `Snaglist Pro` entitlement in the server allowlist.

The durable row contains a keyed hash and a normalized amount, currency, environment,
RevenueCat event-generation time, and subscription period start. Consent must predate
both provider timestamps. The endpoint returns HTTP 200 for accepted and exact replayed
events; an authenticated event older than the relay window is acknowledged without
dispatch so it cannot cause an endless provider retry. The row does not retain the webhook body, transaction identifier,
subscriber attributes, aliases, email, or RevenueCat customer payload. One App Store
transaction is one monetary fact even after restore or account transfer.

This package treats only `INITIAL_PURCHASE` and `RENEWAL` as positive payment facts.
`CANCELLATION`, `EXPIRATION`, and `REFUND_REVERSED` are also normalized in the
lifecycle ledger. An ordinary cancellation and expiry carry zero monetary effect.
Only a `CUSTOMER_SUPPORT` cancellation with a verified negative purchased-currency
amount becomes a latest-period refund; an exact positive reversal can settle it.
Missing, contradictory, cross-account, and unmatched facts remain `unresolved` or
`pending_charge` and never contribute invented net revenue. Distinct provider event
IDs remain separate from the global transaction charge key, so redelivery cannot
create another charge or another refund delivery. A bounded refund must exactly
match the charge currency and negate its amount; its reversal must exactly negate
that refund. Conflicts remain quarantined after later deliveries. Refunds and
reversals reconcile in either arrival order. Account deletion removes delivery-ledger
links and account joins while retaining only hashed event/charge tombstones required
for deduplication.

Resolved cancellation, expiry, refund, and refund-reversal facts can reach PostHog
under the same product-analytics permission and exact environment gate. Refunds and
reversals are never sent to LinkedIn or Singular. Earlier-period refund completeness,
billing issues, uncancellation, product changes, subscription extension, entitlement
reconciliation, and access control remain outside this ledger and must not be inferred
from its rows. RevenueCat remains the operational entitlement authority.

No account-created conversion is emitted. Consent obtained after account creation
cannot make the earlier creation a sign-up, and existing login/authentication paths
must not backfill it. A future sign-up conversion needs the separately designed,
short-lived one-use pre-auth consent capability.

## PostHog EU relay

Set `POSTHOG_PROJECT_API_KEY` to the project's public ingestion key and set
`POSTHOG_MEASUREMENT_ENVIRONMENT` to the exact `sandbox` or `production` project.
Then enable
`productAnalyticsEnabled` only after the EU project has been checked. Delivery is
fixed to `https://eu.i.posthog.com/capture/`. Payloads use the per-purpose opaque
subject and the event allowlist; they do not contain an account ID, email, project
content, free text, RevenueCat identifier, or Apple token.

Provider erasure remains fail closed and `manual_required` until a verified adapter
and completion receipt are implemented. The reserved `POSTHOG_ERASURE_URL` and
`POSTHOG_PERSONAL_API_KEY` settings are inert in production; a generic 2xx, 202, or
404 is not treated as proof of deletion.

## LinkedIn conversions

Store the browser-generated access token only in the deployment secret store as
`LINKEDIN_CONVERSIONS_ACCESS_TOKEN`. The adapter reserves
`LINKEDIN_SIGNUP_CONVERSION_RULE_ID`,
`LINKEDIN_SUBSCRIPTION_CONVERSION_RULE_ID`, and `PLATFORM_ENVIRONMENT`; only the
subscription rule is used by the verified transport contract. RevenueCat currently
does not prove which installation originated a purchase, so lifecycle ingestion does
not enqueue LinkedIn or Singular work by borrowing ATT from another device. Enable
`linkedInConversionsEnabled` only
after the access token, production/sandbox rule, verified-email policy, and provider
receipt have been checked. The token must never enter a database row or log.

LinkedIn erasure is deliberately `manual_required` until a supported provider
deletion contract is confirmed. API receipt means only that LinkedIn received the
request; it does not prove attribution or a matched member.

## Singular boundary

The names `SINGULAR_SERVER_EVENT_URL`, `SINGULAR_API_KEY`, and
`SINGULAR_ERASURE_URL` are reserved but inert in production until the official V2
form-encoded event contract and a provider erasure completion contract are implemented.
The encrypted SDID manifest is retained while erasure is manual. These variables and
`crossCompanyAdsEnabled` must remain unset/false while the native Singular runtime,
automatic AdServices evidence, MMP overlap, and exact provider endpoint contract are
still under review. The generic adapter and mock tests are integration scaffolding;
they are not evidence that Singular is active.

`MEASUREMENT_CREDENTIAL_KEY` is a base64-encoded 32-byte key used only to encrypt SDIDs
at rest. Rotate it only with an explicit manifest migration; replacing it in place
would make pending provider erasure manifests unreadable.

## Operational behavior

The existing cleanup schedule leases and dispatches the durable outbox, then processes
provider erasure, then evaluates account-deletion gates. A current permission revision,
active per-purpose subject, current feature flag, and fresh installation-bound ATT
observation are rechecked under the account lock before every cross-company send.
That account lock remains held during the single provider request (up to 20 seconds)
so withdrawal or deletion cannot race past an already authorised send. A slow
provider can therefore delay a permission mutation or account deletion for that
account by the request timeout. The on-device StoreKit flow is unchanged, but any
same-account server operation that needs to write the locked user row can wait,
including an entitlement refresh if that path updates the row. Treat this as an
activation and performance gate rather than claiming the worker is nonblocking.
Ambiguous transport outcomes become `uncertain` and are not blindly replayed. Rate
limits use bounded retry state. Configuration or request failures require manual
review. No provider call is made by tests without an injected synthetic transport.
