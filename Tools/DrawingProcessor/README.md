# Internal drawing byte processor — local acceptance package

This is the bounded DRA-02 byte-processing implementation, not a deployed feature or a production isolation design. It has no API routes, database calls, scheduler, R2 credentials, storage gateway or drawing graph activation. It leaves the existing photo pipeline unchanged.

The `processor` directory contains sealed-descriptor source verification, bounded process supervision and JPEG/PNG processing. `nojbig2` contains the final PDF helper and the small policy patch for the exact Ubuntu Poppler source. `runtime` creates a **build intermediate** with pinned dependencies. The accepted PDF candidate is the custom no-JBIG2 build; never use the distribution-library intermediate to process customer PDFs.

Run the portable harness on an authorised local Docker host with an already available reviewed base image and the three exact Poppler source archives:

```sh
python3 run_acceptance.py \
  --archives /absolute/path/to/authenticated-source-archive-cache \
  --output /absolute/path/to/new-evidence-directory \
  --base-image snaglist-unified-staging:91a53d9 \
  --expected-base-id sha256:11b2587710a73da3c7dc3dff0e6e29b4b4a62d2ef698c6eaf7c850b5017128dc
```

The output directory must be new. Use `--docker` if the permitted executable is outside PATH. The harness does not pull an arbitrary base, prune images, reset data, use application secrets, push or deploy. It preserves logs, immutable image IDs, input hashes and the runtime profile. It creates local intermediate/candidate images for review and removes only its own temporary context. The tests generate construction-style geometric fixtures inside a disposable confined container; no source/customer directories are mounted into it.

Required source archives, fetched at exact version `22.02.0-2ubuntu0.13` through authenticated Ubuntu apt source indexes, are:

| File | SHA-256 |
|---|---|
| `poppler_22.02.0.orig.tar.xz` | `e390c8b806f6c9f0e35c8462033e0a738bb2460ebd660bdb8b6dca01556193e1` |
| `poppler_22.02.0-2ubuntu0.13.debian.tar.xz` | `bfc89f306a074e2ba93c350fe1664fec8e3dc2aa20e03cd169e5919c3cac9c7c` |
| `poppler_22.02.0-2ubuntu0.13.dsc` | `5c5ce31fa0239ae512e25ff168e1a8de3d7f7932cea7ca97fd27c2ed4f16128a` |

The original investigation retains its authenticated index/repository/source-fetch evidence and archives outside this repository. To rebuild elsewhere, retrieve that exact source version from authenticated Ubuntu source repositories or use the preserved archive cache; do not silently upgrade, change mirrors to an untrusted source or bypass a hash failure. The Docker build verifies all archive hashes, extracts/applies distro patches with `dpkg-source`, compares the complete 891-file source manifest, rejects unexpected source symlinks, then applies the narrowly scoped policy. The extracted third-party tree and build products are not committed here.

The policy removes the `JBIG2Stream.cc` compilation unit and replaces the central stream-filter factory branch before construction or globals resolution. A decoder encounter fails the whole job with a safe unsupported-filter code, including object/xref stream cases. The build verifies absence of decoder symbols and the helper's explicit linkage to the custom library. This targets [CVE-2019-9545](https://ubuntu.com/security/CVE-2019-9545); it does not declare every remaining dependency free from vulnerabilities. Affected scanned PDFs must be re-exported using supported compression; keep their originals available for recovery.

The profile checks actual Linux/amd64 and fingerprints installed packages, code, native libraries, fonts, CMaps and encoder settings. Output identity is `drawing-linux-byte-v1:<profile SHA-256>`. DRA-01's `drawing-initial-v1` is a placeholder and cannot silently adopt these bytes. Any upgrade requires a new profile and immutable processing result. Direct package versions are pinned and all resolved runtime versions/hashes are recorded; historical package availability is not guaranteed, and a future changed transitive dependency must not be treated as the old profile.

Security boundaries remain explicit:

- The sealed descriptor prevents path substitution from changing verified bytes rendered. Trusted verifier/cleanup code preserves original files on normal failures. A compromised same-UID decoder could still reach a writable input path: durable originals must stay outside its writable reach in the production design.
- The parent validates bounded JPEG markers/dimensions and hashes. Fixtures fully decode output; this is not independent attestation of arbitrary hostile-child entropy data.
- Rlimits and environment filtering are not filesystem/network or cross-job isolation. Docker here is a local harness, not an assumed capability inside Cloudflare's deployed Vapor container. A real supported single-job, secretless hosting boundary must be implemented and verified before activation.
- Private immutable source/output storage, current lease/ACL revalidation, actual job retries and profile negotiation remain required. No ready asset is published by this package.
- PDF custom PageLabels remain unsupported; labels are physical one-based page numbers. JPEG/PNG are normalised to RGB without a promise of arbitrary ICC colour-managed fidelity.

Maintain the narrow patch by reviewing each new authenticated distro source, re-establishing factory coverage/decoder absence, rebuilding and running the full byte/geometry/resource suite. Preserve the exact source archives, patch, helper/build source, profile and image evidence for every distributed image. Poppler's upstream licence is supplied as `COPYING.poppler`; see `THIRD-PARTY-NOTICES.md`. No existing app/backend/portal licence is changed by this package.
