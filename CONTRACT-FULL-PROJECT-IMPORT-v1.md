# Full selected-project source contract v1

Prepared 12 September 2026. This additive package decodes and audits the **actual complete native selected-project export**, retaining exact bytes. It creates no import session, ownership claim, media asset, canonical record, membership, notification, database row or executable queue entry. Existing diagnostic preview remains unchanged and non-executable.

## Source and API

`LegacyProjectImportSource` mirrors all 187 fields across the native `DeviceLegacyProjectExport` root and 16 nested record/value types. It retains original project/snags references, ordinary metadata, source timestamps/IDs, both photo label representations, original/thumbnail/annotation roles, drawing page hint/pins, relevant directory/folder/tag edges, unverified comments/status changes and non-executable deletion receipts. No narrow report DTO is used. The source model remains distinct from a future canonical write model.

Use `LegacyProjectImportDecoder.decode(bytes, expected:)`, followed by `LegacyProjectImportGraphValidator.validate(decoded, capacity:)`.

- `expected` contains exact export SHA-256/byte length, selected project UUID and archive source fingerprint from independently retained caller state. It is not obtained by trusting a newly received body's own claims. A later coordinator must bind that state to current actor/workspace/API/device/operation and deliberate acknowledgement; this pure API establishes none of those rights.
- Native currently hashes sorted-key `JSONEncoder` output with its **default Date strategy**: numeric seconds since 2001-01-01. ISO-8601 and Unix timestamps are not this wire format. Use the fixture and exact encoder compatibility probe; do not hash re-encoded server JSON as if it were the original source.
- Original input bytes and SHA remain in `LegacyProjectImportDecoded`, together with the typed source. Whitespace/key-order/UUID-spelling differences remain different exact sources even when decoded values are equivalent. Optional omitted/null fields decode to nil, while exact input bytes preserve their original representation.
- All fixed version/purpose/provenance/limitations markers are required and checked. Unknown fields at any typed object, missing required fields, duplicate keys (including escaped aliases), wrong field types, malformed Unicode/JSON, unsupported versions and binding mismatch are rejected. Raw strings containing legacy label JSON are preserved; they are not execution instructions.
- The decoder's closed field table is pinned to the actual native schema. Adding fields requires a deliberate version/compatibility change and new fixtures; no `additionalProperties` pass-through may silently drop data.

## What graph validation means

The immutable result includes all source record UUIDs by kind, every source relationship edge (including absent targets), every file-role use with parent/position/availability, a unique declared archive-file inventory, total declared bytes, deterministic source issues and an explicit publication budget. Lists are never truncated. Source arrays remain in their original order in the descriptor; normalised audit outputs sort deterministically. The original descriptor—not re-encoded DTO output—is the retained source of truth.

Validation rejects duplicate UUIDs within one record kind, duplicate relationship IDs, child records belonging outside the selected project/snags, conflicting declarations for the same archive path, unsafe asserted paths, invalid checksums/role metadata, malformed source-list/count metadata and oversize input. UUIDs in distinct record categories are not automatically treated as a global identity collision; current canonical collision and access checks still belong to the staged-import service.

Unresolved source facts remain explicit issues alongside preserved values: missing relationship targets/inverse mismatch, folder/comment cycles, invalid pins, source/archive findings, omitted source findings, unavailable inventory, unknown photo labels, missing/unsafe/empty media, incomplete attachment lists, live-snag/deletion overlap, legacy workflow state and unverified drawing provenance. An issue does not discard a record or replace it with a default. No “ready to import” or “accepted” capability is produced. `executionAuthority` remains `none`, `mediaVerification` remains `source_declarations_only`, and `historicalAcceptance` states that no canonical decisions were created.

The result is a **source graph**, not a canonical business-validation pass: old empty/long/unknown text, historical assignment/archive values, decimals, dates and source ownership still require the actual canonical validators and the agreed conversion/reconciliation policy before commit. Historical author IDs, source team ID and deletion owner IDs are raw unverified values, never user membership edges. Source capture/hash assertions cannot authenticate their author or establish server possession of bytes.

## File and history rules

Eight roles are explicit: project cover, photo original/thumbnail/annotation, drawing file/thumbnail, comment attachment and deleted-photo retention. For each, preserve source path/hash, relative archive path, byte size/content hash, availability and legacy drawing-root marker. `position` preserves repeated attachment/deletion-file ordering; photo sort order and dates remain in the source records.

A `verifiedBytes` source value means **the source exporter claimed local archive verification**. This contract does not read/upload/decode those media bytes. The later storage stage must stream exact bytes from the retained archive, verify them independently, use server-generated private role-specific keys, and record immutable upload receipts. Equal bytes may share storage within the same authorised import, but every parent/role survives and equal hashes never establish cross-account ownership. Missing, unsafe and not-recorded references are distinct; zero-byte declarations are retained as a repair issue.

No PDF source relationship exists in this export. A drawing's known raster remains its source surface; its pageNumber is an unverified historical hint, not an index into a guessed PDF. Loose original PDFs remain in the recovery archive. The package creates no source-PDF association or pin transformation.

Source comments/status changes are typed unverified history. A local after label does not create a completion intention. A local closed status does not create a verified approval; the fixture retains its old closed time/name and marks reconciliation. Deletion receipt identifiers are deleted-snag UUIDs, not server receipt UUIDs. Historical `needsRemoteDeletion = true` is retained but never enqueued.

Mention and attachment list hashes/lengths are source declarations: unreadable raw list bytes stay in the archive. An unreadable/not-recorded attachment list cannot supply invented detached file entries. The complete source may contain private contact information, free text and paths; never put it in ordinary request/error logs, analytics or a Contractor response. Neither source retention nor a later export endpoint may bypass current redaction/permission rules.

## Bounded publication profile

Hard limits before any publication:

| Bound | Value |
| --- | --- |
| Exact JSON bytes | 1 byte–8 MiB |
| JSON nesting / nodes | 8 / 300,000 |
| A scalar string / any JSON array | 256 KiB UTF-8 / 50,000 elements |
| Source records / declared relationship edges | 10,000 / 50,000 |
| File-role uses / unique declared files | 50,000 / 20,000 |
| A file / total unique declared bytes | 2 GiB / 2 GiB |
| Source string-list values / original source-list size | 1,000 / 256 KiB |
| A count collection / count value / retained findings | 100 / 100,000 / 1,000 |
| Current publication journal / complete snapshot | 1,000 events / 10,000 rows |

The first full-source projection profile conservatively budgets:

`2 × sourceRecords + declaredEdges + 2 × uniqueDeclaredFiles + 2 × fileRoleUses + 4 × drawings + 3 × pin-bearingSnags + 1`

The terms budget canonical/source-provenance records, all relationship bindings, retained byte identities, per-role binding/asset overhead even for equal-byte aliases, drawing asset/page/version/page overhead, pin/event/provenance overhead and a final import receipt. Optional absent roles still count conservatively. These are **upper-bound slots for the proposed projection**, not claims about tables already implemented or actual upload success. The later mapping/commit builder must assert that its actual row/event plan fits this profile and the live service limits; adding another emitted type requires revising the profile and its tests. It may not assume an unlimited generic graph service.

Snapshot budget also includes `existingWorkspaceDirectoryRows`, supplied from current authorised server inventory—not the untrusted source or defaulted to zero by an HTTP client. Directory overlap is intentionally overcounted. Impossible base-record count is rejected early; the full relation/file budget is checked after audit. A valid source can exceed publication capacity and is then rejected without partial graph output or canonical writes. The caller retains original source bytes for a larger supported import path. This initial bounded profile does not satisfy the separate large-project launch gate.

The synthetic fixture consumes **135 upper-bound slots** before existing directory rows. It contains 16 source records, 40 explicit edges, 14 role uses, 12 unique declared files, one drawing and two pin-bearing snags. A future implementation must not split an oversize project into visible partial batches to evade these limits; hidden staged publication/background snapshots need a separately implemented compatible contract.

## Independent backend verification — 12 September 2026

The actual backend target was rebuilt from clean `35b0033d9cf050483f2f938ce8a67ee15e55d62f` plus the exact seven frozen files, preserving dependency pins and warm caches. `LegacyProjectImportContractTests` passed **24 tests, zero failures and zero skips**, finishing at **22:53:31 UTC**. The tests took 0.339 seconds after compilation. No database configuration, application-service request, provider operation, target-repository change or deployment was part of this run.

The tested `Sources`/`Tests` assembly SHA-256 is `1a4dc4ec75f1cb783db1d405ecb230582dacad983c30feb03601db7b7a9152d4`. The report SHA-256 is `88bb3277701b0f690e9e6d70a4bcf0b5d2ebc2295708372565017dd9c94f07ad`; the complete log SHA-256 is `62bea2fd36c73ed1d0859caaf1ef0f85f46c5467cdaac63b518a592c518d98fe`. The coordination handover retains these as `work/full-import-contract/backend-integration-review/BACKEND-TEST-RESULT.json` and `backend-tests.log`. Report case lists and complete logs were independently matched. This document's validation text was updated afterward; the three implementation files, test source and two fixture files are unchanged.

Independent schema inspection confirmed all **187 native properties across 17 typed objects**, including optionality and object/array shapes, match the backend DTO and closed decoder table. The rich native-generated fixture covers every one of those field keys. The original native encoder source and its recorded output also match the frozen native-source/fixture hashes. Review found no blocking defect in this bounded source-validation contract. Its preserved issues and non-executable authority markers remain essential limitations, not failed implementation work hidden by a passing test.

The original actual-target build reported the two new fixture JSON files as unhandled, one existing `jwt` dependency-packaging warning and a deprecated test-runner `--skip-update` option. The parent then made the narrow manifest-only correction `AppTests.exclude = ["Fixtures"]`, retaining the checkout-based `#filePath` loader. Independent `swift package dump-package` and `describe` checks both succeeded without diagnostics: the contract test remains discovered, both exact fixtures remain at their tested paths, and fixture JSON is excluded from source discovery. No unchanged tests were rerun for that metadata-only correction. `Package.resolved` remains SHA-256 `73662f28607595910f57af43c7b04ba4489b7e61ef38938f32888bbd110fc268`; the final package manifest is SHA-256 `c05e2bfc9232eec1001f6701762da09aab758385d975bfd49cdd4d4d4b1d2124`. `PACKAGE-VERIFICATION.json` retains that check separately from the test run.

Checkout-based loading is suitable for these SwiftPM tests while the checkout is retained. Executing a prebuilt test binary without its source checkout would require a separate resource-bundle/`Bundle.module` change and verification. On Linux, the conditional import uses the already-resolved Swift Crypto 3.15.1 (`95ba0316a9b733e92bb6b071255ff46263bbe7dc`); its SHA-256 API is also used by existing backend services. This API/source inspection is **not a Linux compile or test pass**. Linux integration, runtime transport, staged persistence, canonical mapping, full media/drawing sync and native acceptance remain open.

## Portable fixture and integration

`Tests/AppTests/Fixtures/legacy-project-full-v1.json` is 15,574 exact bytes produced by the **real native source type and JSONEncoder** in the independent harness, not a handwritten imitation of its date/UUID encoding. Its source names and phone/email values are synthetic. It contains Willow Court Plot 12, two referenced snags, three photos with original/thumbnail/annotation and conflicting historical/current label representations, one raster sheet with asymmetric pins, contractor/trade, a two-folder ancestor chain, tag, threaded historical comments/attachment, status history and deleted-snag retention. All ordinary fields are exercised, including fractional costs and dates. The twelve small fixture media files are real PNGs or a text attachment; their exact bytes are portable in `legacy-project-files-v1.json` as base64 with paths/sizes/hashes; a test checks every declaration against these bytes. Their visual content is deliberately tiny test pixels, not a design screenshot or a decoder-quality acceptance fixture.

Only these additive backend paths are proposed:

- `Sources/App/DTOs/LegacyProjectImportSource.swift`
- `Sources/App/Services/LegacyProjectImportDecoder.swift`
- `Sources/App/Services/LegacyProjectImportGraph.swift`
- `Tests/AppTests/LegacyProjectImportContractTests.swift`
- `Tests/AppTests/Fixtures/legacy-project-full-v1.json`
- `Tests/AppTests/Fixtures/legacy-project-files-v1.json`
- This portable contract document (relocate under the repository's documentation directory if preferred).

Do not register routes/migrations, enable existing previews or call a real database when integrating this package. The native encoder probe, archive fixture bytes, generation scripts and minimal Foundation harness are review/test evidence only; they are not app source or a new production runtime dependency. Backend source uses CryptoKit where available and the existing Swift Crypto module on Linux. The actual macOS backend target compile and focused tests now pass as recorded below. Linux integration compile remains open; neither macOS result establishes the deployed Linux runtime.

Run this CPU-bound bounded decoding/audit away from the serving event loop when a future transport calls it. Check cancellation/deadline before handoff and use current actor/workspace/API/operation leases around every subsequent async storage/DB step. The absence of network code here is not a replacement for those fences.

Next complete coding unit: staged private source/session + role upload receipts and normalised preservation graph, then atomic canonical mapping/commit and complete graph download. It must consume this typed source and exact digest, preserve unsupported/missing facts, respect current authority and explicit acknowledgement, and prove native cold-reopen/readback before any import-complete or release claim.
