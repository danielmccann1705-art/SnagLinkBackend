"""Dedicated Linux child launcher. No shell, inherited credentials, or preexec_fn.

The enclosing worker must run in the documented isolated container. These rlimits
are resource bounds, not a filesystem/network sandbox.
"""
import os
import resource
import sys

if __name__ == "__main__":
    if len(sys.argv) < 2 or not os.path.isabs(sys.argv[1]):
        raise SystemExit(64)
    resource.setrlimit(resource.RLIMIT_AS, (768 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CPU, (90, 91))
    resource.setrlimit(resource.RLIMIT_FSIZE, (10 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    os.execve(sys.argv[1], sys.argv[1:], {
        "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
        "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1",
        "PYTHONDONTWRITEBYTECODE": "1", "TZ": "UTC",
    })
