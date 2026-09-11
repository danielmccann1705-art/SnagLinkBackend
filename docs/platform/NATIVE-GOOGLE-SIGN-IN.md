# Native Google sign-in — implementation and verification

11 September 2026. This is a development checkpoint, not release acceptance.

## Executive assessment

The iOS app now contains Google sign-in and explicit same-account connection, using Google's official SDK. The full staging app builds and runs in Xcode 26.2 on the iPhone 17 Pro iOS 26.2 simulator. The final test run passed **148 tests, with 10 historical network-dependent tests skipped and no failures**, including all eight new Google-flow tests.

**Actual native Google authentication remains unverified.** The running staging app could not confirm Google availability at its configured backend. It displays a persistent explanation and retry button; it does not launch a provider against a different environment. The corresponding Vapor endpoints exist and are tested locally, but are not established as deployed on the native staging address. Google web linking and returning sign-in were previously verified against the isolated local Vapor/Neon environment; that evidence does not establish the native round trip.

No production records, external email, pricing, merge, push, production deployment or App Store release changed. This work does not complete account-partitioned native storage or general project synchronisation.

## Exact source

| Repository | Branch / application commit | Scope |
| --- | --- | --- |
| `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink` | `feature/unified-platform` / `f9fb682781cfde7079a73c03169baa5c449f61c1` | Native Google implementation; parent `c4b8360ca5f0646b387c7ee0485a87dc16b6ebfc` |
| `/Users/danielmccann/Desktop/Projects/SnagLinkBackend` | `feature/unified-platform` / `1abdb42` | Matching challenge/identity/session/connection endpoints; later documentation commit `cbec001` |
| `/Users/danielmccann/Documents/Codex/2026-09-06/her/SnaglistPortal` | `feature/unified-portal` / `eafe6a0` | Previously verified browser Google flow; later documentation commit `05b42a8` |

Native source was clean before this slice and is locally committed. Other repositories' pre-existing unrelated files remain untouched. Documentation commits may subsequently advance the branches without changing the tested application source.

## Behaviour and files

Paths below are relative to the native Git root above.

| File / symbol | Behaviour |
| --- | --- |
| `Snaglist/Services/NativeGoogleFlow.swift` — `NativeGoogleFlow.run` | One interactive attempt, explicit sign-in versus connection purpose, account/revision checks after every suspension, expiry/client validation, cancellation and duplicate-tap protection. Provider proofs stay in local variables. Uncertain connection reads the same account; it never silently repeats a one-use proof. |
| `Snaglist/Services/NativeGoogleAPI.swift` | Separate ephemeral, uncached, cookie-free, one-shot transport. Uses the selected API and existing native bearer. HTTPS required; redirects rejected; bounded response decoding; safe user-facing failures. Does not use the general API retry queue. |
| `Snaglist/Services/NativeGoogleProvider.swift` | Official GoogleSignIn 10.0.0; server challenge nonce; registered native/server client pair; presenting view controller from the actual window; exact callback scheme. Clears SDK sign-in state after obtaining the transient proof. |
| `Snaglist/Views/Auth/GoogleAccountControl.swift` | Official Google button only after matching service configuration is confirmed. Sign-in and Settings connection reuse one control. Availability retry preserves the email draft. Connection explains that existing identity, company access and subscription remain on the same account. |
| `Snaglist/Views/Auth/LoginView.swift` | Shared Plex/Marker/Ink/Stone form for Settings, onboarding and share prompts. Email sign-in, retry and Back are real controls. Removed non-functional password/SMS decoration. Existing Apple handler remains available in production; staging Apple registration is still absent. |
| `Snaglist/Services/AuthManager.swift`, `AuthManager+MagicLink.swift`, `APIClient.swift` | Backend UUID continues to identify the user and purchases. Google uses existing authentication adoption. Session revision prevents delayed Google/email/backend-Apple responses from replacing a changed account. The previous LoginView Apple completion ignored success; it now invokes the existing AuthManager handler. Live Apple revalidation remains required. |
| `Snaglist/Views/Settings/SettingsView.swift`, `Snaglist/App/SnaglistApp.swift` | Common sign-in sheet, connected-account control and Google callback before existing link routing. No navigation rewrite. |
| `Snaglist/Info-Staging.plist`, `Snaglist.xcodeproj/project.pbxproj` | Google configuration only for `com.snaglist.app.staging`; release plist remains unchanged. SDK linked to full app, not App Clip. |
| `Snaglist.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Exact resolved graph checked in deliberately despite existing ignore rules. Google 10.0.0; RevenueCat remains 5.58.0. No user workspace state included. |
| `SnaglistTests/NativeGoogleFlowTests.swift` | Eight actual production-flow tests; also runnable in strict Swift 6 standalone mode. |

## Configuration and lifecycle

Google project `snaglist-508309` remains External / Testing. The web client is `853801285577-30r97pllr86pc86eq82ogdh6mjeh2370.apps.googleusercontent.com`. The staging iOS client is `853801285577-umo2ith1f73rvn8g7802hj9a1sjevmd0.apps.googleusercontent.com`, bundle `com.snaglist.app.staging`, Apple team `52ZZHYHM62`. These are public configuration identifiers, not secrets. No production Google client, published consent screen or production callback has been configured. The app refuses to borrow staging clients for `com.snaglist.app`.

The native route sequence is `GET /api/v2/auth/google/configuration` → `POST /api/v2/auth/google/ios/challenge` → official provider proof → `POST /api/v2/auth/google/ios/verify`. Connecting an already authenticated account instead uses `POST /api/v2/account/google/challenge` and `/verify`, with same-account status at `GET /api/v2/account/google`. The server verifies the Google proof and produces the existing Snaglist authentication response; provider email alone never merges identities. Connecting requires recent authentication. There is no unlink/recovery UI yet.

The staging app retains its existing separate store, Keychain service and disabled purchases/push configuration. **Within an environment, existing SwiftData and legacy queues are not yet separated by authenticated account.** Google identity correctness is not evidence that changing accounts on the phone safely partitions all local project data. Do not expose the multi-account pilot until WP-06 and migration checks pass.

GoogleSignIn 10.0.0's bundled privacy manifest declares SDK collection categories. No Drive/Contacts scope or additional scope is requested here. Reconcile the actual integrated SDK manifest and telemetry with App Store privacy answers before release; no privacy claim or App Store metadata was changed in this slice.

## Build and test evidence

Evidence root: `/Users/danielmccann/Documents/Codex/2026-09-06/her/work/unified-platform`.

| Check | Result / evidence |
| --- | --- |
| Command-line baseline, before native edits | Exit 74 before compilation: `sandbox-exec: sandbox_apply: Operation not permitted` during package manifests; CoreSimulator connection unavailable. `ios-google-baseline-build.log`. Historical environment failure, not a source pass. |
| First full GUI SDK compile | Failed once on an incorrectly assumed Google error enum name. Fixed to the actual SDK's `GIDSignInError.canceled`. Original `1B6A4F6D-77A7-465D-AA24-32E466D267E4.xcactivitylog` retained. |
| Final changed app build/run | Succeeded, 13:07:44–13:07:53 BST; `894D7B05-8374-447A-ACB9-A55AC4F5278E.xcactivitylog`. Three emitted instances of an existing `APIClient+Approvals.swift:126` actor-default warning. Actual UI launched. |
| Final Xcode XCTest | **148 pass / 10 skipped / 0 failed**, 13:13:34.966–13:13:54.682 BST. `native-google-xctest-final.xcresult`, `native-google-verification-final.json` and expanded result JSON. Test build succeeded with the existing `MagicLinkSendManagerTests.swift:139` retroactive Equatable warning. |
| Google flow coverage | Backend identity adoption; connection without account adoption; account changes at issue/provider/exchange and same-account relogin; cancellation/fresh retry/view invalidation; duplicate provider attempts; expiry/environment validation; explicit identity/reauthentication/purpose errors; uncertain connection read-back without replay and uncertain sign-in without invented success. All eight pass. |
| Strict Swift 6 standalone production flow | Eight checks pass. `native-google-flow-tests.log` and `native-google-flow-compile-final.log`. This is supplementary; the full UIKit/Google SDK app also compiled and tested above. |
| Source verification | `native-google-final-source-files.json` hashes match the committed sources. Project/plist lint and Git whitespace checks passed. |

The ten skipped tests are the five historical networked `ApprovalServiceTests` and five networked `AuthManagerTests`; their identifiers are recorded in the final JSON. They do not pass merely because the remaining suite does. No signed device, archive/Release, live Apple/native Google, native capture/sync or App Store acceptance is claimed.

Xcode GUI now supplies a working build/test route. The earlier statement that no fresh native build was possible is superseded. Command-line sandbox limitations remain; do not disable sandboxing, erase simulators or reset other projects to work around them. No Xcode restart is currently required.

## Actual visual/interaction inspection

Captures are in `/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/portal-design`; saved unchanged using Simulator's Save Screen, not rendered prototypes.

- `native-google-sign-in-unavailable.png`: real availability failure and retry action.
- `native-google-draft-retained.png`: synthetic email draft survives Google retry and text-size changes; no sign-in email was sent.
- `native-google-dark.png`: the same actual form in dark appearance.
- `native-google-largest-text.png`: header/body reflow after eight text-size increases. **Lower-form scrolling at the maximum size is unverified:** simulator scroll and drag automation did not move the viewport. This is an unresolved inspection limitation, not an established app scrolling defect or accessibility pass. Original text size and appearance were restored.

Normal-size labels, disabled empty-email action, valid-email enabling, Google retry and Back/navigation were inspected through the simulator accessibility tree. Full VoiceOver, keyboard, all text categories, Google provider button/window, error announcements and physical-device testing remain open.

The native project overview still shows old PLOT navy/cyan/blueprint styling and “Magic link” copy. Settings still contains older orange/system treatments and unverified real-time collaboration claims. These are recorded remaining design/product defects; the native app is not yet visually aligned throughout. The approved v1.1 Marker/Ink/Stone/Plex direction remains controlling.

## Next dependency order

1. Preserve this native checkpoint and continue manager Add/share/link workflows against the existing canonical APIs; keep uncertain operations immutable and drafts/context intact.
2. Complete native account-scoped stores/media/queues, recoverable legacy ownership/import and canonical pull/outbox before enabling the shared multi-account journey.
3. Establish matching Vapor Linux staging and private R2 processing; register the real staging Google server configuration. Exercise native provider cancellation, fresh sign-in, explicit link, relaunch/session expiry and correct same-account browser access. Keep email/Apple compatibility checks separate.
4. Complete remaining company profile/branding/seats/test billing and manager workbench; preserve no-account Contractor links.
5. Prove G1 with ordinary native capture, two real internal identities, contractor evidence, acceptance and matching native/report output. Complete D1 recording/native-report comparison and integrated D2, including unresolved native visual/accessibility work.

Authoritative brief: `05 - App build and engineering/Snaglist_Unified_Platform_Implementation_Plan_2026-09-10.md`, v1.1, refreshed 11 September; Drive modified time remains `2026-09-10T04:59:30.275Z`. Prior web implementation and provider evidence: [GOOGLE-SIGN-IN-VERIFICATION.md](https://drive.google.com/file/d/1zdtUA4jIr4l0Wj05RHm6tVDnVx_h2Mmr/view). Company scope/evidence: [COMPANY-ADMINISTRATION.md](https://drive.google.com/file/d/1vDRg162rYTTKVdlS6Y9EaDZrsAlBbGb6/view).

Provider references checked for this implementation: [Google iOS integration](https://developers.google.com/identity/sign-in/ios/start-integrating), [backend authentication](https://developers.google.com/identity/sign-in/ios/backend-auth), [official SDK releases](https://github.com/google/GoogleSignIn-iOS/releases).

## Drive capture copies

- [native-google-sign-in-unavailable.png](https://drive.google.com/file/d/1v9ImHq1pO603b3PCnmSvEJvlbBnKSKHK/view)
- [native-google-draft-retained.png](https://drive.google.com/file/d/1VIx3q3eFJSDvNdBYpPQJgOQO5viaRPZi/view)
- [native-google-dark.png](https://drive.google.com/file/d/1YCY8NHxrc1JYPZZyxn9pgbM78Qgh4EI8/view)
- [native-google-largest-text.png](https://drive.google.com/file/d/13kVBcuISF_3d36Z25IeJIqIHEKnTiSlZ/view)
