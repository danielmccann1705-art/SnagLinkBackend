# Google sign-in and company administration — scope amendment

## Domain wiring and approved monthly mailbox — 11 September 2026

The existing website is now live at **https://usesnaglist.com**, with HTTPS and a tested www → apex redirect. **https://staging-api.usesnaglist.com/health** returns 200 as an additive alias to the existing 9 September staging deployment. Resend **mail.usesnaglist.com** is Verified; the deployed sender is still on the old domain and new-domain message delivery has not been tested. DNSSEC activation is pending. Existing .dev routes are preserved; production API health remains 530 and the manager portal is not deployed.

**Google Workspace setup is complete and tested.** Dan's one Business Starter mailbox is `dan@usesnaglist.com`; `hello@`, `support@` and `billing@` are free aliases into that inbox and saved Gmail sending identities. All three inbound test messages were received. Hello and support initially landed in Spam; both legitimate tests were reported as not spam, with all three then visibly in Inbox. Replies automatically selected the appropriate alias, and **all three outgoing replies reached Dan's personal inbox with SPF, DKIM and DMARC passing**. Dan remains the default sender for new messages. The current Admin subscription confirms **Active, Business Starter, one assigned licence, Flexible Plan, £7.00 per user/month before tax**. Checkout showed paid service starting 25 September; the subscription page shows the next billing date as **1 October 2026**. These are different milestones. No extra user or annual commitment was added. The temporary Google session interruption was resolved; no further sign-in is needed for this completed mailbox setup. See [DOMAIN-CONFIGURATION.md](https://drive.google.com/file/d/15Itk0Yvjib5FagJ22Gx4oRQiOIVwqq_y/view) for evidence and remaining platform-domain work. Workspace mailbox acceptance does not verify Resend or customer sign-in/Contractor links; those retain the previous deployment limitations.

## Approved provider expansion — 11 September 2026

Dan explicitly approved all four sign-in methods: **Google, Apple, Microsoft and email link**, for the app and manager web companion. Microsoft is now required scope rather than a later optional suggestion. Contractors retain their separate no-account Contractor link experience.

Microsoft must support organisational and personal Microsoft accounts, resolve a stable verified provider identity with its issuer/tenant context, and explicitly link to an existing authenticated Snaglist account. Do not merge by email, infer company membership from an email domain, transfer a subscription, or bypass project permissions. Request authentication/profile identity only; no mailbox, calendar, contacts, Drive or Graph-content access is required. Use official provider UI/SDK guidance, environment-specific configuration and the same replay/session/CSRF/account-switch guarantees as the other methods. Customer email hosting is independent of the offered login methods.

Acceptance includes first and returning sign-in on phone/web, explicit same-account linking, collisions, cancellation, expired/replayed proofs, organisation policy errors, personal-account coverage, account recovery/deletion/provider cleanup and retained workspace/purchase identity. An unfinished or unconfigured provider must not appear to work. Microsoft code/configuration and actual provider verification are **not implemented by this scope update**; Apple web configuration and native Google staging verification also remain open. Native account-scoped storage/sync is a prerequisite to public multi-account use.

**usesnaglist.com is registered and Active in Cloudflare.** The latest domain and mailbox checkpoint above supersedes the registration-only status. Preserve old .dev API and Contractor-link compatibility; production authentication origins and sender delivery still need verification.

Reference: [Microsoft supported account types](https://learn.microsoft.com/en-us/entra/identity-platform/howto-modify-supported-accounts). The following dated checkpoints remain historical evidence.

## Earlier checkpoint — native Google implementation, 11 September 2026

Native **f9fb682** (`feature/unified-platform`) now implements Google sign-in and explicit same-account connection with the official SDK. The final staging app builds and runs in Xcode 26.2; **148 tests pass, 10 historical network-dependent tests are skipped, zero fail**, including all eight new Google-flow tests. Actual simulator captures show the shared Plex/Marker/Ink/Stone sign-in form, retained email draft, availability failure/retry and dark appearance.

**Live native Google is still unverified:** the staging app could not confirm the matching service configuration. The Vapor implementation and prior real Google web verification use an isolated local development environment. Neither is a deployed native-provider or production pass. The GUI build supersedes the earlier blanket native-build blocker; command-line sandbox limitations remain. No Xcode restart is currently needed.

Read [NATIVE-GOOGLE-SIGN-IN.md](https://drive.google.com/file/d/1IJ8jV4RHapOacGS7wZp-_-f8682POEut/view) and the [native evidence bundle](https://drive.google.com/file/d/1WdWN9qTUug-hJlfoFTmfIAh8sZuegL8w/view) for exact source, files, tests, configuration and limitations. Largest-text header reflow is captured; lower-form scrolling and full VoiceOver are unverified. Native Projects/Settings still have older styling/copy and unsupported real-time collaboration claims to resolve.

**Next:** manager Add/share/link workflows; account-partitioned native stores/media/queues and recoverable import/outbox/pull; matching Linux/private-R2 staging and real native Google; remaining company branding/seats/test billing/workbench; ordinary native/two-manager/contractor G1 and complete D1/D2. Full native sync, team billing and the platform are not complete. No merge, push, production cutover, live prices or App Store release occurred. Earlier entries below describe their dated source checkpoints.

## Earlier checkpoint — Google web sign-in, 11 September 2026

Backend **1abdb42** (`feature/unified-platform`) and portal **eafe6a0** (`feature/unified-portal`) implement Google authentication and explicit same-account linking. **Actual Google browser sign-in is verified in the isolated development environment:** linking, chooser cancellation/retry, logout and returning through Google retain the existing synthetic account and company Owner access. A read-only database check confirms one Google identity alongside the original email identity and unchanged active ownership. This is not production or native Google acceptance.

Read [GOOGLE-SIGN-IN-VERIFICATION.md](https://drive.google.com/file/d/1zdtUA4jIr4l0Wj05RHm6tVDnVx_h2Mmr/view) for current source/file paths, configuration, migration/rollback constraints, endpoint map, actual captures and the [evidence bundle](https://drive.google.com/file/d/1XI461SgKAnUQWspY7-Pyhd95h8UOckbg/view). The new Google cookie exposed a confirmed Vapor parsing defect; the fix preserves secure session/PIN cookies and independent sign-in tabs. The official provider button now resizes without changing its nonce. Company and project context remain in place while account settings is open.

**Evidence:** 59 identity/current-and-legacy-Contractor cases pass after the cookie fix; a separate **25-case final run passes at 1abdb42**, including two simultaneous sign-in challenges. These are source-specific runs on a retained isolated Neon database, not an exact-final 59-case suite or fresh production database. Portal contract/types/build and **50 tests pass at eafe6a0**. Actual 320/390/768px constrained-frame checks found and fixed button overflow; final mobile captures are 390px. No physical-device, exact full-window dimension, 200% zoom or complete D2 pass is claimed.

**Still open:** native Google SDK/UI and real native-provider verification; native account-partitioned sync/import/outbox; manager Add/share/bulk/link management; company profile/branding/seats/test billing; plans/reports/durable jobs; private R2/Linux staging; G1 and remaining D1/D2 evidence. The 11 September recheck reports Xcode 26.2 but a disconnected CoreSimulator service, so there is no fresh native build. Local Google clients and External/Testing consent are configured; production clients/publication remain absent. Older-session Google linking currently asks the user to save work and sign back in; smoother reauthentication/disconnect recovery remain work to finish.

The v1.1 brief was fetched again and its revision note, section 12 design gates, working product defaults and handoff instructions were checked. No merge, push, live pricing, production deployment or App Store release occurred. Preserve the existing native reskin, branches and unrelated work. The following checkpoint text is dated history.

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
