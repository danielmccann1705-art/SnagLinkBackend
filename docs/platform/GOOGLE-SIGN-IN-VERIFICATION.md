# Google sign-in — implementation and verification

11 September 2026. This is a development checkpoint, not production or App Store acceptance.

## Executive assessment

**Google sign-in works in the browser against the actual Google provider and the isolated development backend.** Explicitly connecting Google, cancelling the provider chooser, signing out and returning with Google preserves the existing Snaglist account and its company Owner access. The iOS exchange is implemented and tested with signed synthetic identities; **the native Google SDK/UI is not implemented or provider-verified yet**. Do not describe Google sign-in as released on both platforms.

This extends the [company administration checkpoint](https://drive.google.com/file/d/1vDRg162rYTTKVdlS6Y9EaDZrsAlBbGb6/view). Company members, invitations, roles, project permissions and activity have their own evidence there. Company profile/branding, seats and test billing remain separate incomplete work. No live price or production entitlement changed.

The controlling [v1.1 implementation brief](https://drive.google.com/file/d/1d7H-EvCfdrc0GVPGnNEXHhJVeG-SbOlL/view) was fetched again on 11 September; Drive still reports its 10 September 04:59 UTC revision. The supplied Snaglist v2 brand assets, Plex type and semantic web styles remain controlling. Google supplies its prescribed sign-in button inside this system.

## Source and status

| Item | Status and evidence |
| --- | --- |
| Backend repository | `/Users/danielmccann/Desktop/Projects/SnagLinkBackend`, branch `feature/unified-platform`, final application commit **1abdb42**. |
| Portal repository | `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal`, branch `feature/unified-portal`, final application commit **eafe6a0**. |
| Google verification boundary | **eccea56**: signed identity verification, issuer/audience/presenter/nonce/time checks and eight cryptographic tests. |
| Identity and challenge persistence | **098b4f0**: explicit linking, one-use challenges, transaction rollback, revocation and concurrency tests. |
| HTTP exchange | **4dabe5d**: browser/native exchanges, explicit account-linking routes and contract. |
| Cookie interoperability | **1abdb42**: confirmed Google-cookie parsing defect fixed; per-challenge browser binding supports two open sign-in tabs. |
| Web interface | **37ac5f2**, then **eafe6a0**: Google button, account connection, cancellation/error handling, same-document email-link reception and responsive button sizing. |
| Native repository | `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink`, branch `feature/unified-platform`, clean and unchanged at **c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc**. Native Google SDK, controls, URL routing and provider verification are absent. |
| Production | None of this milestone has been merged, pushed, deployed to production, or released to the App Store. Existing recovered Cloudflare routing is unchanged. |

## What the app now does

The signed-out web page offers Google's own button and the existing email sign-in. The Google SDK is loaded from its fixed official URL; it requests basic identity only, with no Drive/contacts access or refresh token. Automatic selection and One Tap are not enabled. Provider proof remains transient in memory and travels only to the same-origin authentication endpoint. It is not placed in storage, URLs, logs or component state.

A signed-in user opens **Your account** without unmounting the current project/company work. The panel distinguishes separately verified email addresses from a connected Google identity. The **Connect Google** flow requires a recent authenticated account and Google proof. It does not match a mutable email/name to silently merge accounts or subscriptions. If an existing account may already match, a sign-in collision asks for the existing sign-in method and explicit connection. A Google contact email does not become a verified work-email identity for company invitations.

The provider's stable subject maps to the existing Snaglist user. Explicit linking keeps the existing user ID, profile, primary authentication provider, company membership and purchase identity. Another user's Google identity cannot be transferred, and a second different Google identity cannot replace the connected one. Successful repeated linking of the same identity/account is idempotent.

A Google attempt has a ten-minute challenge, fresh nonce and browser/native binding. Server storage contains hashes of the challenge, nonce and binding, with purpose, surface, environment, origin, provider configuration and intended account/session. Verification checks the signature, fixed Google issuer, exact server audience, native authorised presenter where relevant, expiry/issued time and nonce. Challenge consumption and account/session creation or linking commit in one transaction. Revoked accounts/sessions and replay fail closed.

Browser success returns the existing Secure/HttpOnly/host-only session cookie plus CSRF response. Native success returns the existing revocable Snaglist bearer-token response. Native-only exchange rejects browser Origin and Sec-Fetch-Site headers. Account linking requires current browser CSRF/Origin or a current native bearer token, with authentication within ten minutes. All successful Google responses are no-store.

## Browser defects found and fixed

1. **Google's cookie could hide Snaglist's credential cookie.** The existing Vapor generic directives parser treats commas/quotes in Google's JSON-valued `g_state` as header structure. Depending on cookie order, email verification returned a misleading wrong-browser error and a successful sign-in could immediately lose access to projects. This was reproduced in a failing server regression before the fix. `RequestCredentialCookie` now reads the exact selected cookie from semicolon-delimited Cookie headers, rejects duplicate/malformed/oversized credentials, and leaves signature/session/PIN checks authoritative. The same correction covers browser sessions, email/Google bindings and both generations of Contractor link PIN checks. Secure cookie settings were not weakened.
2. **Two sign-in tabs competed for one Google binding cookie.** Each challenge now has its own derived cookie name, deleted on successful consumption and expiring independently. Rendering another Google button cannot invalidate the first tab's pending provider proof. A two-tab server test resolves both to one stable user.
3. **Google's button overflowed after narrowing the page.** The actual 390-to-320px inspection produced a 366px-wide document. A ResizeObserver now asks Google's renderer to resize its button while retaining the same nonce/callback. The final 320px page measures 320px, with reachable controls.
4. **A reused email-confirmation tab could ignore a new hash-only link.** The portal now receives and removes a new inbound token on hash navigation before remounting confirmation. A normal GET still never consumes a proof.

## Real provider and browser evidence

Used Dan's approved Google test account, linking it explicitly to the **synthetic Emma Hughes** email account in the isolated review database. The Google chooser/consent requested name/profile and email only. No external test email was delivered; the prerequisite synthetic email sign-in was intercepted by the task-local mail viewer.

Observed through actual Chrome UI:

- Explicit Google connection reports Connected on the existing account.
- Closing the provider chooser leaves the sign-in control usable; reopening it works.
- Sign out followed by Google sign-in returns Emma Hughes and the same company.
- Company Owner administration still lists the existing people and project-access controls.
- A final Google login on **eafe6a0** succeeds after the responsive refinement.
- Opening/closing account settings preserves the member search for Jamie; the existing filtered results remain. Dialog close restores focus to Your account.
- Account settings fit 320/390px iframe widths; sign-in fits 320/390/768px after resizing. This is constrained browser rendering, not a physical phone or 200% zoom pass.

A scoped read-only database check verifies the same synthetic user, original `magic_link` provider, exactly one email identity plus one Google identity, and active company Owner membership. The record `google-browser-integrity.json` contains no provider subject, ID token, session cookie or signing material. This is not a real purchase-restoration test or proof of company billing.

Actual browser captures:
- [Desktop Google/email sign-in](https://drive.google.com/file/d/13of4MO9uYHuEGSuhtO5RfgTFDNqYK5RB/view?usp=drivesdk)
- [Google connected to the existing account](https://drive.google.com/file/d/1fQbQ8OktO7dR3JC95kx9uboUU-1NNs0p/view?usp=drivesdk)
- [Company Owner access after Google sign-in](https://drive.google.com/file/d/1HLI7dZmF3hW_9KEOm4d9vTCI1MRxM6M8/view?usp=drivesdk)
- [390px sign-in frame](https://drive.google.com/file/d/16674YRIXJOKdn3i5_hRjt1yzFowPOItz/view?usp=drivesdk)
- [390px account settings frame](https://drive.google.com/file/d/1rSlfskn0uoFGnmjB7GldXCmbsCbkarve/view?usp=drivesdk)

Desktop captures were taken at **37ac5f2**; the final mobile frames at **eafe6a0**. The later change only resizes the provider renderer and suppresses the alternative-method divider when Google is disabled. Captures preserve the actual browser screenshot bytes; the mobile frames are cropped by the screenshot API using DOM page coordinates. Per-file capture metadata records hashes, versions and the iframe qualification.

[Download the evidence bundle](https://drive.google.com/file/d/1XI461SgKAnUQWspY7-Pyhd95h8UOckbg/view) for unchanged captures, capture hashes, source-specific test results and environment checks.

## Build and test evidence

All automated database runs below use TLS and a restricted role in the retained isolated Neon database `snaglist_platform_test_0911074529_fa3f`. They do not create a new database each run and do not touch customer records. Interactive browser data lives separately in `snaglist_platform_test_0910222943_fc44`.

| Run | Result | Exact source SHA-256 |
| --- | --- | --- |
| `google-identity-locked-final` | 28 passed, 0 failed, 0 skipped | `0f4ae7af4bcb4bca900215f3c934d85f49d9db6348f01b5364a3521e66023db3` |
| `google-auth-http-verified` | 36 passed, 0 failed, 0 skipped | `fd4ceb8ff5d8d5f4d6abbdd7a04fe37d2c4b765ead47f0ea50f88d43f1980da1` |
| `google-cookie-reproduction` | 0 passed, 1 failed, 0 skipped | `783928a7f6e1f7153bb55d9be4fbd36bbdadd9cacc393a125ffe756a2f96f2c5` |
| `google-cookie-fixed-final` | 59 passed, 0 failed, 0 skipped | `d4a9039248fc3d6293cf06f9a8c9f5f1ed066c95841f5c62040559d59afa9618` |
| `google-cookie-two-tab-final` | 25 passed, 0 failed, 0 skipped | `5de73293f6ca4176128d9bfa4b2c9fd6a507399d5fe243728f87255015fbca89` |

The one failing reproduction is intentional evidence of the cookie defect before its fix. A first cookie-test build also failed because a test property conflicted with XCTest's `name`; it was renamed. Successful final runs are distinct from those retained failure logs. The 59-case regression includes legacy/current Contractor links and identity security; the final 25-case run covers the final two-tab refinement at **1abdb42**. Do not describe the 59-case run as an exact-final 1abdb42 full suite.

Portal contract generation/check, TypeScript and production build pass at **eafe6a0**, with **50 tests passed, zero failed/skipped**. Seven new tests cover duplicate callbacks, cancellation/account changes, mandatory recent-account proof, ambiguous exchange/read-back, expiry/collision and same-origin CSRF transport. Production output excludes design fixtures and local storage credential writes. Logs are `google-portal-responsive-build.log` and `google-portal-responsive-tests.log`.

The maintained OpenAPI candidate is **0.10.0**, 64 paths, 78 operations and 86 schemas, copied byte-for-byte from backend `docs/api/openapi.json` into portal `contracts/openapi.json`. `scripts/generate-api-types.py` produces transport-only types. No production environment is implied by that contract.

## Endpoint and file map

| Route | Scope/use |
| --- | --- |
| GET `/api/v2/auth/google/configuration` | Public client IDs only when explicit environment configuration is valid; otherwise enabled=false. |
| POST `/api/v2/auth/google/challenge` | Browser Origin; ten-minute nonce plus HttpOnly browser binding. Rate limited. |
| POST `/api/v2/auth/google/verify` | Google proof + initiating browser binding; secure Snaglist session. |
| POST `/api/v2/auth/google/ios/challenge` | Native-only; iOS client, web server audience, nonce and transient verifier. |
| POST `/api/v2/auth/google/ios/verify` | Native proof/presenter/verifier; existing revocable bearer response. |
| GET `/api/v2/account/google` | Current account connection boolean; no provider identifier/email hint. |
| POST `/api/v2/account/google/challenge` | Current recent account, surface/session/version binding. |
| POST `/api/v2/account/google/verify` | Current recent account plus Google proof; explicit identity connection. |

Backend implementation: `Sources/App/Controllers/GoogleAuthController.swift`; `Services/GoogleIdentityProof.swift`, `GoogleIdentityService.swift`, `GoogleIdentityChallengeService.swift`, `RequestCredentialCookie.swift`, `BrowserSessionService.swift`; `Migrations/CreateGoogleIdentity.swift`; Google/BrowserIdentity/RequestCredentialCookie tests. Existing `AuthController.issueAuthResponse` and `BrowserAuthController.response` retain their response contracts.

Portal implementation: `src/PortalApp.tsx`, `AccountSettings.tsx`, `components/GoogleSignIn.tsx`, `data/googleFlow.ts`, `data/googleProvider.ts`, `api/client.ts`, shared `styles.css`, generated contract/types and `tests/google-flow.test.mjs`. Mutation attempts are not automatically replayed. After a connection interruption, the user can read back session/connection status or explicitly start a fresh provider attempt.

## Provider configuration, environment and operations

Google Cloud project **snaglist-508309** is dedicated to Snaglist. OAuth consent remains **External / Testing** with the approved test account. No production publication, billed Google resource or client-secret download occurred.

| Configuration | Current development value/location |
| --- | --- |
| `GOOGLE_AUTH_ENVIRONMENT` | `local` for this interactive host; must match `PLATFORM_ENVIRONMENT`. |
| `GOOGLE_WEB_CLIENT_ID` | Client named **Snaglist web local development** in the dedicated project. Public ID: `853801285577-30r97pllr86pc86eq82ogdh6mjeh2370.apps.googleusercontent.com`. |
| Web JavaScript origins | `http://localhost:5177`, `http://127.0.0.1:5177`. GIS ID-token popup callback; no redirect URI or client secret used. |
| `GOOGLE_IOS_CLIENT_ID` | Client named **Snaglist iOS staging**. Public ID: `853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0.apps.googleusercontent.com`. |
| Native staging bundle/team | `com.snaglist.app.staging`, Apple team `52ZZHYHM62`. Native Google URL scheme/SDK still to add. |
| Backend/portal | Real Vapor on loopback 55486, Vite review on 5177; existing isolated Neon PostgreSQL, task-local private media. This is not deployed staging/R2. |
| Outbound calls in interactive harness | Real Google public JWKS only; synthetic email intercepted; unrelated outbound calls rejected. |

Google keys come from the fixed official JWKS endpoint through Vapor's cached provider, not a URL from an untrusted token. The Google migration expands provider support, adds the unique per-user Google identity guard and persisted challenges. It has run only in isolated test/review databases here. It deliberately refuses a destructive revert; production rollback needs an expand-compatible application/image and a tested recovery plan, not dropping identity data.

A refresh of the native environment on 11 September reports **Xcode 26.2 / 17C52**, but CoreSimulator cannot connect to its disk-image/runtime service. No simulator devices can be enumerated through the available command connection. The environment report is retained; no caches, simulator data or unrelated processes were deleted. The earlier request to save/reopen Xcode remains relevant. No fresh native build is claimed.

## Remaining work and next integration order

1. Complete native Google SDK/UI, staging client/URL handling and same-account linking, preserving Apple/email methods, Keychain/revocation and RevenueCat stable-user login/restoration. Obtain a current build/simulator connection and prove real native → web identity continuity. Review the existing staging Apple audience mismatch separately; do not change the production Apple audience speculatively.
2. Improve recent-account reauthentication without requiring a sign-out; currently the UI explicitly asks the user to save work and sign back in before linking an older session. Add provider disconnect/recovery rules only with a remaining sign-in method and tested revocation. Google-only new web users currently have no general account email-add control outside the invitation recovery flow.
3. Configure deployed-staging origins, native environments and production consent/branding/privacy URLs when appropriate; exercise the supported browsers and real iOS provider. Google web local Testing consent is not production-ready consent configuration.
4. Continue native account-partitioned canonical import/outbox/pull and the two-internal-user capture → browser → Contractor link → acceptance → native/report journey. Manager Add/share/bulk/link management, company profile/branding, seats/test commerce, plans/reports/durable jobs and private R2/Linux staging remain independent work.
5. Finish D1 recording/current native-report comparison and D2 on real staging, including exact desktop viewports, zoom, keyboard, permissions/conflicts and supported Safari/Chrome/Edge. The viewport override tool encountered detached historical tabs; its set/reset attempts failed. This checkpoint uses labelled constrained-frame checks and makes no full-window dimension/zoom claim.

The user authorised continued implementation and Drive updates. Preserve both branches and existing unrelated work. Do not merge, activate live billing, deploy production or submit an App Store release from this checkpoint.

Provider references: [Google web integration](https://developers.google.com/identity/gsi/web/guides/integrate), [JavaScript nonce/button API](https://developers.google.com/identity/gsi/web/reference/js-reference), [Google iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating), [native backend verification](https://developers.google.com/identity/sign-in/ios/backend-auth).
