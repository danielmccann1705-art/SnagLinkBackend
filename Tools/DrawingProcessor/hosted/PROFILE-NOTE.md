# Processor profile boundary

This packet deliberately leaves `runtime/profile.py`, `nojbig2/profile_extension.py`, and the existing `runtime-profile.json` unchanged. It is a non-processing capability probe and is not an accepted parser runtime.

Before any drawing processing is enabled, allocate a new immutable processor profile that includes the exact launcher binary/source, seccomp rules, supervisor, protocol, scratch/resource policy and native/Python dependencies. Bind that new profile to the exact OCI image digest and wrapper protocol. Do not rewrite `drawing-initial-v1`, reuse the current no-JBIG2 profile, or treat this probe result as a processing manifest.
