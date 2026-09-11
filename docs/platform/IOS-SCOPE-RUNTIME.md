# iOS R1a — scoped device runtime

Updated 11 September 2026. **Implemented on the current branch, with the runtime foundation tested and bounded ordinary staging UI verified. Full native–portal integration, legacy ownership/import, external provider acceptance and release remain incomplete.**

The staging app now mounts a separate SwiftData store, media roots and preferences for its durable guest identity or verified backend account. It preserves older staging work separately. This is the data-safety foundation for shared app/browser work; it deliberately prevents unsafe legacy network operations from pretending to synchronise that new workspace.

## Exact checkpoint and verification

Repository: `/Users/danielmccann/Desktop/Projects/Snaglist/SnagLink`, branch `feature/unified-platform`, local commit **`009f0d18e77fabf27f8d0bebba00345010f7c023`**. Forty-five source/project/test files changed, including 44 Swift files. No push, merge, deployment or release submission occurred. Existing dirty documentation was excluded from the product commit. Production and isolated review composition keep their existing selection paths; the runtime condition is `AppConfiguration.isStaging && !ReskinReview.isEnabled`.

| Check | Actual evidence and limit |
|---|---|
| Full native test run | Snaglist Staging / iPhone 17 Pro / iOS 26.2, 21:47:36 UK run: **348 total, 343 passed, 0 failed, 5 existing skips**. All 12 new NativeScopeRuntimeTests passed. |
| Exact tested source | `work/native-scope-runtime/integrated-source-fix2.json`, 242 files, SHA-256 `8bb1945807426ef29e639164d56aceaaeb0b5365387376cea47c34388229ecdb`. |
| Final two-file UI correction | Banner moved outside the navigation container; live staging empty-state copy corrected. Independently reviewed, no blocker. Actual Xcode build at 22:00:50–22:01:09 UK succeeded with zero errors/warnings; normal UI checks below followed. The full 343-test suite precedes these two files and is not relabelled as a test of the final source. |
| Final committed source | `work/native-scope-runtime/integrated-source-fix3.json`, 242 files, SHA-256 `3c324ace0d5b368f46c90bcb323d0041292890e34894b21dcd011fffc5b303e9`. Only PlotProjectsView and NativeScopeRootView differ from the full-suite manifest. All 45 committed file hashes checked. |
| Original staging data | Main store, WAL and SHM match all three before-test SHA-256 values, again after final UI/recovery checks. Simulator installs relocated the app data directory; metadata located the current container. An absent old absolute path was not data loss. |
| Current workspace recovery | Ordinary UI copied the synthetic guest workspace and displayed “Device records reopened successfully”; three files checked at 22:40 UK. |
| Older work preservation | Ordinary UI copied three original files and checked them. This raw preservation copy does not prove project-level import or ownership. |
| Production / complete sync | Not activated or verified. No R1/R4/D2 release gate closes on these results alone. |

Full and compact evidence: `IOS-SCOPE-RUNTIME.json`, `work/native-scope-runtime/runtime-tests-21-47-36.xcresult`, its legacy JSON and test detail extraction, `ui-fix3-build.json` and activity log, `repository-checkpoint.json`, and `original-staging-preservation-after-ui.json`. Raw databases and recovery archives remain local and are excluded from Drive.

## Implementation and important symbols

- `Snaglist/App/SnaglistApp.swift` selects `NativeScopeRootView` only under the staging runtime gate. It skips the old writable staging ModelContainer in this mode.
- `Snaglist/Services/DeviceScopeFileSystem.swift` composes immutable environment/API-origin/backend-UUID or installation-guest-UUID paths. It reserves a workspace before opening, marks it ready after a successful save, and refuses unlabelled storage, interrupted reservations or a missing established database. There is no empty-store fallback, automatic claim or deletion.
- `Snaglist/Services/NativeScopeRuntime.swift` supplies the tested coordinator with real ModelContainers, fixed photo/drawing services, scoped defaults and a work fence. Freeze stops autosave, unbinds legacy sync, clears obsolete team/widget publication, drains captured work and explicitly saves before preparing the next mount. Only the active resource enables autosave. Detached, old and unknown contexts cannot resolve another account’s media.
- `Snaglist/Views/Shared/NativeScopeRootView.swift` mounts queries/navigation/sheets under a fresh lease identity and captured store/preferences. Previous content disappears during a switch. The brand-styled 44-point banner accurately says work is saved on this device; the settings route exposes scoped recovery instead of global cleanup/deletion.
- `Snaglist/Services/AuthManager.swift`, `AuthManager+MagicLink.swift` and `NativeScopeAuthenticationHandoff.swift` hold verified/restored credentials until the matching workspace mounts. AuthManager owns an accepted Google/email response independently of the disappearing provider presentation task. Newer intents cancel superseded adoption, stale callbacks cannot publish, and failed preparation retains the actual candidate/provider for retry. URL receipt captures context before asynchronous work starts. Real external-provider acceptance remains open.
- Local model/media consumers use their owning ModelContext and fixed resource. Photo capture handles its temporarily detached snag through the owned project context; project covers save before dismissal; drawing imports capture the resource and fence async work. Narrow MainActor annotations on URL getters/export callers resolve actual compiler findings without isolating whole models or using unsafe isolation escapes.
- Four new app files were added to the Xcode project. The test file uses the existing filesystem-synchronised test group. PBX lint and diff checks passed.

## Staging behavior and limits

| Operation | Current staging behavior |
|---|---|
| Local projects, snags, edits and organisation | Available in the selected guest/account store; ordinary project/snags capture verified below. |
| Local photo/drawing/pin/comment persistence | Actual resource-bound paths covered by the new runtime tests. New camera/photo selection, drawing import and full editing UI acceptance remain open. |
| Guest/account switch | Actual runtime separation, preparation failure, supersession and drain/save paths tested using isolated injected fixtures. Real provider-driven A→B→A and physical-device acceptance remain open. |
| Older store | Preserved separately; not mounted writable and never assigned to the next login. Raw copy entry verified. Ownership-backed preview/import and receipts are not implemented. |
| Contractor links, approvals, comments network, reports and business API calls | Explicitly unavailable in this staging slice before legacy network work or output mutation. Their complete scope-bound replacements are still required. Local snag notes remain local. |
| Pending revocation/deletion | Private queues preserved. Unsafe staging replay disabled; no false successful revocation or deletion acknowledgement. |
| Reports/storage cleanup/account deletion | Older global actions replaced or gated. Scoped recovery remains available. No account deletion acceptance is claimed. |
| Production/review/purchases | Existing selection/configuration and commercial terms retained; these builds and real receipts were not newly verified by this slice. |

The new local store is not a canonical project cache yet. No upload, second-device retrieval, portal availability, accepted closure or customer migration is inferred from it. Staging network gating is an interim safety measure and must be replaced by tested immutable operations and complete pull/repair behavior before release.

## Actual ordinary simulator checks

The normal staging app, not the review/demo screen, was exercised with synthetic construction text. Created **Willow Court · Plot 14**, reference **WC-014**, then saved and opened **WC-014-001**, “Front door latch catches on the strike plate”, with description, Medium priority and Plot 14 / Ground floor / Entrance hall location. The project survived the banner rebuild/relaunch. Both the empty and populated register were observed.

The photo library picker opened and was cancelled; no stock landscape image was presented as construction evidence. The saved snag therefore honestly displays “No photo”. Actual attachment and file persistence are covered by isolated runtime tests, not this new UI capture.

The detail Share with contractor action displayed the explicit staging notice and returned correctly. Approvals and Reports tabs displayed their own unavailable notices. Settings scrolled to both recovery routes. The older-work route copied and checked three original files. The current-workspace route copied and reopened the synthetic records successfully. No customer record, email, provider token or API mutation was used.

A real initial defect was fixed: the top safe-area banner clipped Projects navigation controls. The sibling banner layout now leaves the title and buttons visible. Other older native visual treatments, full large text, VoiceOver, physical camera, all sheet/account transitions and full D2 remain open. Some navigation items were visible in screenshots but absent from the automation accessibility tree; this is not a VoiceOver pass.

## Screenshots

All are actual unedited simulator captures. Drive readback matched every uploaded file byte-for-byte.

- [Before: clipped navigation banner](https://drive.google.com/file/d/1aOKAM332piMiUb_AqzL67uz8q3wTSoFB/view?usp=drivesdk) — `outputs/readiness/native-scope-header-before.jpg`.
- [After: Projects header and persisted project](https://drive.google.com/file/d/1Tr9WGmRhGPIIBm6coOkeK_hokTxs1_Wd/view?usp=drivesdk) — `outputs/readiness/native-scope-projects-after.jpg`.
- [Empty project snag register](https://drive.google.com/file/d/1YZiajgByfIKTh32TFBq2KL9NkaCRKhXd/view?usp=drivesdk) — `outputs/readiness/native-scope-empty-register.jpg`.
- [Populated project snag register](https://drive.google.com/file/d/1jLtpFSlu4OlR4mcp4KWbRdC-98Y_57i3/view?usp=drivesdk) — `outputs/readiness/native-scope-populated-register.jpg`.
- [Contractor-link staging boundary](https://drive.google.com/file/d/1KC69Li2GhMDX0sObK-yueahLUud7Cfb5/view?usp=drivesdk) — `outputs/readiness/native-scope-sharing-gate.jpg`.
- [Checked legacy preservation copy](https://drive.google.com/file/d/1DQpuRuNVjIAINuBW7pcaP0BrA6cEad7N/view?usp=drivesdk) — `outputs/readiness/native-scope-legacy-preserved.jpg`.
- [Checked and reopened guest recovery copy](https://drive.google.com/file/d/1TT4tKsds15bvpcxE3CnELswRpV8MdxIs/view?usp=drivesdk) — `outputs/readiness/native-scope-recovery-verified.jpg`.

## Corrected failures and review history

The 21:40 UK attempt was cancelled for the Xcode project reload and ran no tests. The 21:41 build exposed six actor-isolation errors in computed photo/profile URLs. Correction 1 isolated the narrow accessors and dependent PDF/Excel callers; no gate was weakened. The 21:44 app then compiled, but test compilation exposed the nested runtime fixture’s missing MainActor annotation. Correction 2 annotated that fixture factory/helper. The corrected 21:47 full run passed as recorded above, with two existing test-only SendAction Equatable warnings. Failure bundles and both correction patches remain in `work/native-scope-runtime*`.

Independent review before integration corrected concrete lifecycle risks: installation validation, interrupted store recreation, autosave durability, inconsistent onboarding defaults, report/share bypasses, retry identity, late URL context capture and provider-presentation cancellation. The final v3 source/patch was checked independently; the final two-file UI delta was also reviewed against its manifest. Source parsing, nine standalone filesystem cases and two compiled accepted-handoff interleavings supplement, but do not replace, the real Xcode results.

## Dependency-ordered continuation

1. Finish ordinary account/provider, large-text and remaining recovery/media/navigation acceptance on staging. Preserve original device bytes and fail visibly rather than claim unsupported migration.
2. Implement an ownership-backed legacy review/import journey: inspect a disposable verified copy, show ambiguous/missing relationships and files, require an explicit destination with current server authority, preserve stable aliases and issue durable import receipts. Never infer ownership from the next login or matching contact text.
3. Complete canonical drawing/media and remaining graph coverage before advertising it. DRA-01 supplies internal transactions; DRA-02 supplies a tested local byte processor, not a deployed gateway or projection.
4. Implement immutable, account-bound native outbox/import mappings and full discovery/bootstrap/delta/conflict/retry/revoked-access repair. Capture intent at edit time; reject stale edits over accepted closure and preserve unresolved local work.
5. Prove the ordinary native → distinct second manager → scoped PIN Contractor link → evidence → accepted closure → native/fresh-device/report journey against the matching isolated staging service. Complete providers, company admin/test billing, durable jobs/reports and D2 before a release disposition.

The maintained launch plan remains authoritative. No production activation, release upload, submission, merge, Git push or live Team billing occurred.
