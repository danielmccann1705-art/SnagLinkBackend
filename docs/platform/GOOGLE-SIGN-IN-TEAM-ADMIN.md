# Google sign-in and company administration — scope amendment

Recorded 11 September 2026 from Dan's direct instruction during the authorised v1.1 implementation campaign. This adds requirements; it is not evidence that these capabilities are implemented or released. Preserve the approved brand pack, native reskin and current portal design system.

## Google sign-in on iOS and web

Add Google's supported sign-in to both surfaces, resolving the same stable Snaglist user and workspace memberships. Keep existing Apple/email entry points and purchase restoration. Google login is authentication only: request basic identity scopes; it does not request access to a customer's Drive, contacts or other Google content.

Verify Google-signed identity tokens server-side, including signature/key rotation, issuer, explicit environment-specific client audience, expiry and request binding/replay protection. Browser sign-in must maintain its exact Origin, CSRF, one-use challenge and secure session-cookie boundaries. Native exchanges produce the existing revocable Snaglist session rather than treating a client-supplied email/Google ID as proof.

Use the provider subject as the Google identity key. Linking Google to an existing Apple/email account requires explicit proof of that current account and the Google identity. Matching mutable profile email or names is never enough; third-party email addresses on Google accounts are not automatically treated as ongoing control of that mailbox. Account collisions need a clear, retained recovery/linking journey; do not silently transfer identities or subscriptions.

Provider setup required: dedicated Google Cloud OAuth configuration; iOS client IDs for each bundle/environment; web/server client IDs; approved web origins and redirect handling; iOS URL scheme; consent-screen/verification disposition. Values are configuration, not invented placeholders that appear as working login buttons. Live provider acceptance remains unknown until configured and exercised on both surfaces.

Acceptance must cover valid same-account sign-in on phone/web, explicit linking, cancelled/failed login, wrong audience/issuer, expired/replayed credentials, wrong browser binding, removal/revocation and restoring the existing purchase identity. Keep Google's prescribed sign-in button treatment within Snaglist's layout.

Primary references: [Google iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating), [backend identity verification](https://developers.google.com/identity/sign-in/ios/backend-auth), [web integration](https://developers.google.com/identity/gsi/web/guides/integrate), [web nonce configuration](https://developers.google.com/identity/gsi/web/reference/js-reference).

## Comprehensive administration for team plans

Interpret this as customer company Owner/Admin administration within the manager portal. Preserve the existing Team/workspace model and central access policy. The following screens and operations are required:

- Company profile and report branding, with clear separation from personal projects.
- Members and invitations: verified recipient, pending/expired/revoked states, resend/copy flow, membership activation, role changes, immediate removal and ownership transfer.
- Project access: explicit Manager/Member grants, project-level scope and meaningful permission explanations. A company role or paid seat must not silently expose personal projects.
- Plan and seats: purchased capacity, assigned/available seats, member allocation, concurrent final-seat acceptance, unassigned/pending states and a clear preview of any financial change. Contractors consume no seat.
- Billing management: verified plan/status, test checkout and provider customer portal, invoices/payment-method routes, renewal/cancellation/payment-failure states and entitlement reconciliation. Provider events, not a redirect or purchase button, determine access.
- Activity and audit: who changed membership, permissions, ownership or plan; timestamp, target and outcome. Do not expose credentials, contractor bearer links or private unrelated records.
- Operational usability: searchable member/project lists, empty/loading/error states, protected destructive actions, accessible controls and retention of filters, selection and drafts through ordinary workflows.

This does not authorise a platform-wide support impersonation console or unrestricted operator access. Any such internal operations surface needs a separate explicit scope. Team pricing and live billing activation retain the existing commercial gate; no new tariff has been approved by this amendment.

## Dependency order

Continue the current verified completion/media slice and its connected design review. Extend WP-01 with Google identity/provider configuration and same-account linking, then carry company administration through WP-02/WP-08 and seats/test billing through WP-10. Include native/web Google flows and all company administration states in functional evidence and D2. Provider setup can run alongside backend/UI work, but fixtures must not stand in for provider or purchase verification.

Current evidence at this checkpoint: backend `7b4c8cd` passes 226 tests on a fresh isolated Neon PostgreSQL 16 database (0 failed, 0 skipped), including 8 canonical workflow tests. Portal `f763ae2` builds and passes 31 tests. Google sign-in is newly required and not implemented; the full company administration scope is incomplete. Native full build, real staging journey, D1 recording and D2 remain open.
