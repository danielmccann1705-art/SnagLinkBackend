# Hosted drawing sandbox capability probe

This is a **local-only capability packet**. It accepts no drawing bytes and cannot invoke the parser. Its only successful operation is `--probe`. A successful local run is implementation evidence; only a run on the exact hosted image and instance type can satisfy the hosted gate.

The native launcher fails closed unless it can establish and verify:

- an unprivileged user namespace plus distinct mount, PID and network namespaces;
- PID 1 with a namespace-local read-only `/proc` containing no supervisor process;
- a read-only root and dependency tree;
- a private 512 MiB, 4096-inode `nodev,nosuid,noexec` tmpfs;
- one retained output-directory descriptor and closure of a synthetic inherited supervisor socket plus all other descriptors;
- empty effective, permitted, inherited, bounding and ambient capability sets;
- `no_new_privs` and an amd64 seccomp allowlist;
- `EPERM` for IPv4, IPv6 and Unix sockets, connect/sendto (including DNS), process creation, ptrace, process-memory reads, `pidfd_getfd`, new namespaces/mounts, `io_uring`, and privilege changes.

Any missing syscall, namespace, mount permission, status proof, exact result field, timeout or malformed output becomes only:

```json
{"identifier":"drawing_sandbox_unavailable","status":"unavailable"}
```

## Local checks

Run the host-independent tests:

```sh
cd Tools/DrawingProcessor/hosted
python3 -m unittest discover -v -s tests
python3 -m py_compile protocol.py supervisor.py tests/*.py
```

Build only from the reviewed no-JBIG2 candidate. `FROM` needs either a verified
local tag or a registry-qualified digest reference; a bare `sha256:...` value is
parsed as a Docker Hub image name and is not valid here:

```sh
docker build --platform linux/amd64 \
  --build-arg PROCESSOR_IMAGE=snaglist-drawing-nojbig2:reviewed-local \
  -f Tools/DrawingProcessor/hosted/Dockerfile -t snaglist-drawing-hosted-probe:local .
```

For a registry image, use
`registry.example/snaglist-drawing-nojbig2@sha256:<reviewed-manifest-digest>`.

Then run with outer network disabled and without adding privileges:

```sh
docker run --rm --platform linux/amd64 --network none snaglist-drawing-hosted-probe:local
```

An unavailable result under ordinary local Docker is a valid rejection, not permission to add weaker fallbacks. Extra local privileges can diagnose the implementation but do not prove hosted support. Do not create a remote Container, paid resource, registry image, or deployment from this packet.

## Hosted gate still required

Run the same immutable image on the selected hosted instance with outer internet disabled. Record the image digest, instance class, kernel, result bytes and wall time. Do not accept a cached/local result, and do not send a source before the probe returns exact ready evidence. Container root is not assumed to have `CAP_SYS_ADMIN`; inability to create the trusted mount namespace or bounded tmpfs is a hard `drawing_sandbox_unavailable` result.
