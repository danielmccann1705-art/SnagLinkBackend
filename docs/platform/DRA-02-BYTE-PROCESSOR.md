# DRA-02 — actual drawing byte processing

Prepared 11 September 2026. **Implemented and tested as an internal local package: the final archive-based Linux build passed 31 test methods, with zero failures or skips. Not deployed, API-integrated or approved as production isolation.**

The isolated processor verifies original PDF/JPEG/PNG bytes, produces real page and thumbnail JPEGs, and builds a typed manifest from parser geometry and measured encoded output. The final source-archive build removes the JBIG2 decoder before construction and passed the complete 31-method suite, including actual crop/rotation/pixel checks, eight unsupported-filter paths, source preservation, output tampering and confinement/resource tests. Earlier implementation/test failures are retained below rather than presented as passing final-source evidence.

Source is under [work/dra-02](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/dra-02), based on backend documentation HEAD `a8d73cd6d06c9cd3197641a05f7c114da342c5c7` and DRA-01 product commit `9e5d13e433778e8adf1b0767d5d1e6b9fac529ff`. The exact 19-file, approximately 200KB package is committed on `feature/unified-platform` as `801db7433c18f9f5d773481c4ca6a436fd2623da`, confined to [Tools/DrawingProcessor](/Users/danielmccann/Desktop/Projects/SnagLinkBackend/Tools/DrawingProcessor/README.md). All current and committed repository bytes were independently read back against `work/dra-02/repo-package-source.json`; all 19 hashes match the reviewed package. The final acceptance applies to the identical shared processor/build/test sources; no additional test run is claimed after copying them into the repository. This task has not changed database schemas, deployment, R2 credentials, native/portal source or the frozen `91a53d9` candidate. Root owns other simultaneous source/documentation work. The drawing schema foundation remains separately documented in [DRA-01-IMPLEMENTATION.md](/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/readiness/DRA-01-IMPLEMENTATION.md).

Repository entrypoints: [README](/Users/danielmccann/Desktop/Projects/SnagLinkBackend/Tools/DrawingProcessor/README.md), [repeatable acceptance runner](/Users/danielmccann/Desktop/Projects/SnagLinkBackend/Tools/DrawingProcessor/run_acceptance.py), [final PDF runtime](/Users/danielmccann/Desktop/Projects/SnagLinkBackend/Tools/DrawingProcessor/nojbig2/Dockerfile), [third-party notices](/Users/danielmccann/Desktop/Projects/SnagLinkBackend/Tools/DrawingProcessor/THIRD-PARTY-NOTICES.md).

## What is implemented

| Boundary | Actual implementation and limitation |
|---|---|
| Original identity | `processor/worker.py`, `Allocation`, `verify_source`: exact declared SHA-256/byte count/MIME, bounded streaming copy, format framing, inode metadata comparison, regular single-link file requirement. Source is opened relative to a trusted directory descriptor with no-follow/nonblocking flags. Original display names, URLs and object keys are not decoder inputs. |
| Immutable parser input | Verified bytes are copied to a Linux memfd and sealed against writes, resizing and seal changes. Only that descriptor is inherited by the decoder. Path replacement after verification cannot change the bytes rendered. Trusted verifier/cleanup code never overwrites, renames, chmods or deletes the caller original, including normal processing failures. This does not protect a writable source path from a compromised same-UID parser and is not a durable object-store upload. |
| Real raster decode | `processor/raster.py`: explicit JPEG/PNG decoder selection, full structural/decode checks, no truncated or animated images, EXIF orientation applied, transparent pixels composited onto white, clean RGB baseline JPEG output. Source metadata is stripped; arbitrary embedded ICC colour-managed fidelity is not claimed. |
| Real PDF decode | `nojbig2/processor/drawing_pdf.cpp`: pinned Poppler core parser and Splash renderer. Raw inherited MediaBox/CropBox/Rotate are parsed with bounded, cycle-checked dictionary traversal and checked against the parser's effective display geometry. UserUnit is read from the actual page dictionary. Repaired, encrypted, unsupported-geometry and error-bearing documents fail. |
| Measured coordinates | Raw PDF coordinates map to the existing `display_top_left_v1` convention. Four rotations and nonzero/differing crop/media boxes are checked against actual rendered pixel colours, including crops partly outside the media box. Image coordinates use upright decoded pixels. |
| Real encoded outputs | Generated `page-NNNN.jpg`, `thumb-NNNN.jpg` and bounded `pages.json` only. Supervisor validates exact allowed filenames, regular files, JPEG markers and actual encoded dimensions against geometry, and hashes actual encoded bytes. Duplicate JSON keys, nonfinite/bad geometry and unexpected metadata reject. |
| Failure containment | `bounded_run` drains capped stdout/stderr while the child runs, enforces a wall deadline, kills/reaps its process group and removes only its own partial job output. Raw parser text is not returned; safe fixed failure codes identify parse/geometry/render/encoding/unsupported-filter failures. |
| Runtime identity | `runtime/profile.py` plus `nojbig2/profile_extension.py` bind code, helper/custom library and resolved dependency bytes, fonts/configuration/CMaps, package inventory and encoder settings. Manifest profile is `drawing-linux-byte-v1:<profile SHA-256>`; it is deliberately different from DRA-01's placeholder `drawing-initial-v1`. |

The manifest has the existing DRA-01 source identity and page geometry/hash/size shape. It does not call `CanonicalDrawingService.finishProcessing`, create a storage key, allocate an asset, update a lease or publish a drawing. No client can submit this manifest through a public route. Custom PDF PageLabels are not preserved yet: `sourcePageLabel` is explicitly the physical one-based source page number, not an inferred document label.

## Hard limits and the hosting boundary

| Limit | Enforced value |
|---|---|
| PDF / JPEG or PNG input | 50 MiB / 10 MiB, exactly matching allocation |
| Raster decode | 12,000 pixels per side; 40 million pixels |
| PDF | 1–100 pages; finite positive ordered source boxes; 0/90/180/270 rotation; bounded physical extent and scale |
| Rendition / thumbnail | Maximum side 4,096 / 512 pixels; white background; baseline RGB JPEG quality90, 4:4:4, no optimisation/progressive encoding/metadata |
| Output storage | 10 MiB per encoded file; 256 MiB combined; 1 MiB metadata |
| Child process | 768 MiB address space; 90 CPU seconds; 120-second supervisor wall deadline; 64 descriptors; zero core dumps; 10 MiB file-size limit |
| Diagnostics | 16 KiB combined stdout/stderr, drained while running; no image/PDF payload on stdout |
| Local test container | Non-root, network-none, read-only, no host/secret mounts, capabilities dropped, no-new-privileges, 32 processes, 1.5 GiB memory, one CPU, 512 MiB tmpfs |

**Docker is the local acceptance harness, not an assumed capability of the deployed Cloudflare Vapor container.** A production single-job processor still needs an implemented, provider-supported design with equivalent secret, process, filesystem and network isolation. Environment filtering and rlimits alone do not prevent same-UID `/proc` access or isolate different jobs. The current tests run synthetic fixtures in a disposable container containing no other customer job or backend credentials; they do not prove production cross-job isolation. The sealed descriptor preserves the verified bytes consumed by the decoder, but a compromised same-UID process could still reach the writable synthetic input tree. Durable originals must remain outside the parser’s writable reach in the production design. Similarly, parent JPEG validation checks bounded markers/dimensions and actual hashes; full output decoding is exercised by fixtures, not independently attested against a hostile compromised child. Do not wire this helper directly into the credential-bearing API process/container.

## Decoder security and reproducibility

The initial image uses Jammy Poppler `22.02.0-2ubuntu0.13` and Pillow `9.0.1-1ubuntu0.5`. Canonical's [USN-8400-1](https://ubuntu.com/security/notices/USN-8400-1) and [USN-8690-1](https://ubuntu.com/security/notices/USN-8690-1) identify those backported versions as fixes for specified issues. An apt candidate is not a blanket vulnerability-free claim.

Canonical still lists [CVE-2019-9545](https://ubuntu.com/security/CVE-2019-9545), affecting JBIG2 decoding, as vulnerable with a deferred fix for Jammy. The ordinary distro image can reach that decoder when rendering PDFs and must not be enabled for customer processing on this evidence.

The custom candidate uses the exact authenticated `.13` distro source. `nojbig2/patch_poppler.py` verifies the 891-file extracted source manifest, replaces the sole `Stream::makeFilter("JBIG2Decode")` construction branch with a fixed rejection **before resolving JBIG2Globals**, and removes `JBIG2Stream.cc` from the compiled core. The build asserts that the resulting library contains no `JBIG2Stream::` symbols. Utilities/Cairo/wrappers and HTTP support are disabled in this dedicated Splash build. The helper binds the custom library through an explicit rpath; it does not silently overwrite the distribution's installed library.

Any encountered unsupported JBIG2 filter latches a failure for the entire job. The EOF wrapper is an internal parser termination mechanism, never a successful blank page. Specific tests exercise ordinary content, filter arrays, escaped and indirect names, abbreviated filter keys, globals, object streams and xref streams, require the safe `unsupported_pdf_filter` result, preserve original bytes and permit no partial output. A harmless filter-name comment is the negative control against a raw byte scan. The final archive-based custom image passed all 31 test methods, including these paths and the same ordinary valid-document controls. This targeted removal addresses the named decoder path; it is not a comprehensive audit of every remaining PDF codec or dependency.

Repeat determinism is scoped to the same pinned Linux profile. The corrected fixture run proves identical PDF geometry, profile and page/thumbnail bytes on two processing attempts. It does not assert that macOS ImageIO, another Poppler/Pillow build or future fonts produce the same bytes. A runtime upgrade requires a new profile and new immutable processing result; do not rewrite existing ready page hashes.

## Independent review and exact source provenance

A separate agent reviewed the factory rejection/error latch, constructor ownership, geometry, descriptor/cleanup behaviour, source pinning and runtime boundary, then accepted the final hardening/harness delta and all 19 package-file hashes. It found no remaining bounded-prototype blocker. The reviewer independently matched final input/profile hashes and the 31-test success log; it did not run a duplicate test suite. Its maintenance findings led to an actual-platform assertion and rejection of unexpected source symlinks; the final archive-based run includes both. Review also clarified that sealed input is not original-path protection against a compromised same-UID child, and header/dimension validation does not independently attest hostile-child entropy data. Those limits remain explicit above.

## Source provenance and maintenance

Source was fetched in a disposable container through default authenticated Ubuntu apt indexes, at the exact distro version; no insecure/trust override was used. `dpkg-source` applied the distro patch series. Evidence is retained in [source-fetch.json](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/dra-02/evidence/source-fetch.json), the signed-index source records and the original archives.

| Archive | SHA-256 |
|---|---|
| `poppler_22.02.0.orig.tar.xz` | `e390c8b806f6c9f0e35c8462033e0a738bb2460ebd660bdb8b6dca01556193e1` |
| `poppler_22.02.0-2ubuntu0.13.debian.tar.xz` | `bfc89f306a074e2ba93c350fe1664fec8e3dc2aa20e03cd169e5919c3cac9c7c` |
| `poppler_22.02.0-2ubuntu0.13.dsc` | `5c5ce31fa0239ae512e25ff168e1a8de3d7f7932cea7ca97fd27c2ed4f16128a` |
| Extracted source manifest | `d54b35a5046a2fa2c82ee120f62d88e28b9f6b6e179bb4d0f6f2244524dd5317` |

The candidate Dockerfile pins build/runtime packages at their observed apt versions. The resulting profile includes the exact installed inventory, resolved dependency hashes and font/CMap data. Build warnings about unused optional package tools must not be interpreted as use of those tools; actual linked-library/profile evidence and fixtures govern acceptance.

Poppler carries GPL notices, including GPLv2-or-later headers and its [COPYING](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/dra-02/upstream/poppler-22.02.0/COPYING). Preserve notices and the exact corresponding upstream+distro source, patch, helper source and build instructions when distributing a processor image; settle the processor package's compatible licensing before external distribution. This task does not relicense the existing app, backend or portal. Keep the authenticated archives/build evidence outside the product source commit; the small patch, hash manifest and retrieval/build instructions are the reviewable maintenance artefacts. `run_acceptance.py` accepts a cache of the three exact archives, verifies the reviewed local base image, stages a disposable build context, builds the final core from those archives and runs the confined suite by immutable image ID. `dpkg-source` reconstructs the distro-patched tree, which must then match the 891-file manifest before the custom patch runs. No existing extracted source tree is required. The initial image is a build intermediate and must not be used as a customer PDF worker.

For security updates: fetch a new authenticated distro source; inspect upstream/distro differences; reapply the narrowly scoped decoder policy only after reviewing its factory coverage; rebuild; verify decoder absence and actual dynamic linkage; run byte/geometry/unsupported-stream/resource fixtures; record a new profile/image digest. The current patch intentionally fails if its expected source or factory differs or any unexpected source symlink is present. The profile generator rejects a different actual OS/CPU instead of mislabelling it Linux/amd64. Keep the old original bytes/profile through migration; no silent renderer replacement under an existing asset.

## Test evidence so far

| Checkpoint | Exact result | Interpretation |
|---|---|---|
| Initial Linux build | C++ compilation failed; no tests ran | Found actual Poppler22 API differences and warnings from distro headers. Preserved `build-initial.log`. |
| Second Linux build | Passed; no runtime acceptance | Exact old constructors and system-header handling compiled. |
| Distro fixture image `edd53c46f66d4b989d40d2b5bdf64bafec2126dd33a17aa1e55afee5ae7fea30` | 27 methods: 22 passed, 5 valid-PDF errors; test process11.611s | Incorrect `GooString` ownership double-freed the filename. Actual source confirmed `PDFDoc` owns/deletes it. Failure evidence retained. |
| Corrected distro image `eea25dcccd98d5d458e35a75227ccb63551352274b72aa585c5e8882b676b33d` | 29 methods: 28 passed, 1 failed method with5 subtest assertion failures | All prior valid-PDF paths passed. Only the test's incorrect empty-workspace expectation remained; changed to assert previous output directories and bytes are unchanged on rejection. Still an unmitigated distro JBIG2 runtime. |
| Initial custom core build | Core/library installation and decoder-symbol absence assertion passed; helper compile failed; no tests ran | Installed headers required both custom include roots. Preserved `build-nojbig2.log`. |
| Corrected custom image `040cfb2cc460d45147658422bdd1f9484abc9f7f0edbb711001b5189cd038e89` | 31 methods passed, 0 failed/skipped; test16.427s / Dockerwall19.772s | Includes eight JBIG2 entry-path subcases and harmless-name control. Profile `cefa6a642a8ebfc1fdd18fc4770d65c2443e5e9765e2790fc175e68d8e48d41a`. |
| Final hardening/archive-based image `47f90cd16a8cab01e8a0948ccb58b9189ce1b17ae9285d6d4029ee2aafac508e` | **31 methods passed, 0 failed/skipped; test16.662s / Dockerwall19.387s; both builds exit0** | Actual-platform assertion, source-symlink rejection and exact-archive extraction all exercised. Profile `0c398d19456a85be07a4999a8a40e30cbcddb5ebde3f2da8f9114fb028f04fcc`. |

The reports are [fixtures-run.json](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/dra-02/evidence/fixtures-run.json), [corrected-run.json](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/dra-02/evidence/corrected-run.json) and `nojbig2-run.json` / `nojbig2-corrected-run.json` plus the final [portable-harness run.json](/Users/danielmccann/Documents/Codex/2026-09-06/her/work/dra-02/evidence/final-acceptance/run.json), each with source hashes, immutable image identity, confinement arguments and separate runtime-profile hash. Do not add overlapping test counts or report failed earlier runs as passing final-source tests.

Additional source/raster/confinement checks exercise wrong identity/signatures, truncation/CRC failure, animation, excessive pixels/pages, encryption, malformed/inherited geometry, all eight JPEG EXIF orientations, transparent PNG, sealed-source mutation and replacement, symlink/hardlink/FIFO/traversal rejection, process-group timeout, actual file/memory limits, output/log caps, encoded metadata/dimension tampering and runtime fingerprint validation. A separate local Poppler26.08 `pdfinfo` check confirms the synthetic encrypted fixture is a valid encrypted PDF; that is fixture validation only, not Linux runtime acceptance.

## Remaining integration and next complete package

1. The reviewed repository package is committed at `801db7433c18f9f5d773481c4ca6a436fd2623da`; its local byte/decoder acceptance is complete. Next implement a supported single-job production isolation design before activating PDF processing; Docker-in-the-existing-backend is not an assumption.
2. Implement a dedicated private drawing-source/page storage adapter with exact immutable keys, source hash/size verification, output persistence/re-read validation, cleanup and real profile negotiation. Reuse the existing R2 client/configuration only after adding drawing-specific purpose and size rules; do not loosen the current photo-only path whitelist/10MiB contract.
3. Connect processing leases/retry/error states to actual stored source/output. Recheck current uploader/project ACL and lease after processing and storage, then pass server-produced facts to the DRA-01 readiness transaction. A lost lease or failed storage write cannot publish ready pages.
4. Add coherent drawing write/read routes, publication and pin change-journal integration, immutable bootstrap/delta coverage and private manager/Contractor-page gateways together with permission/revocation tests. Original PDFs must never leak through selected Contractor pages.
5. Native durable import/outbox/profile handling, private media recovery and second-device reconstruction still follow. Browser/native/Contractor/report visual parity, real staging and D2/R4 remain open. No R1 or launch gate is closed by this helper alone.

No emails, customer files, production/staging/recovery data, purchases, domain routing or credentials were changed by this task. No deployment, push or release submission was performed.
