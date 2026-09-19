"""Strict local protocol for the hosted sandbox capability probe.

This module carries no drawing bytes and cannot admit processing work.
"""
from __future__ import annotations

from dataclasses import dataclass
import json

SCHEMA = "snaglist-drawing-sandbox-probe-v1"
IDENTIFIER = "drawing_sandbox_unavailable"
SCRATCH_BYTES = 512 * 1024 * 1024
SCRATCH_INODES = 4096
REQUIRED_CHECKS = (
    "user_namespace", "mount_namespace", "pid_namespace", "network_namespace",
    "readonly_root", "readonly_dependencies", "bounded_tmpfs", "inherited_fds_closed",
    "no_new_privs", "capabilities_zero", "seccomp_active", "network_denied",
    "dns_denied", "process_creation_denied", "ptrace_denied",
    "process_memory_denied", "pidfd_getfd_denied", "namespace_changes_denied",
    "mount_changes_denied", "io_uring_denied", "privilege_changes_denied",
)


class ProbeUnavailable(Exception):
    """A required kernel boundary was absent or the evidence was malformed."""


@dataclass(frozen=True)
class ReadyProbe:
    checks: tuple[str, ...]
    scratch_bytes: int
    scratch_inodes: int

    @classmethod
    def decode(cls, raw: bytes) -> "ReadyProbe":
        if len(raw) > 16 * 1024:
            raise ProbeUnavailable(IDENTIFIER)
        try:
            value = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ProbeUnavailable(IDENTIFIER) from None
        if type(value) is not dict or set(value) != {"schema", "status", "scratchBytes", "scratchInodes", "checks"}:
            raise ProbeUnavailable(IDENTIFIER)
        checks = value["checks"]
        if (value["schema"] != SCHEMA or value["status"] != "ready" or
            type(value["scratchBytes"]) is not int or value["scratchBytes"] != SCRATCH_BYTES or
            type(value["scratchInodes"]) is not int or value["scratchInodes"] != SCRATCH_INODES or
            type(checks) is not list or any(type(item) is not str for item in checks) or
            tuple(checks) != REQUIRED_CHECKS):
            raise ProbeUnavailable(IDENTIFIER)
        return cls(tuple(checks), value["scratchBytes"], value["scratchInodes"])

    def encode(self) -> bytes:
        return (json.dumps({
            "schema": SCHEMA, "status": "ready", "scratchBytes": self.scratch_bytes,
            "scratchInodes": self.scratch_inodes, "checks": list(self.checks),
        }, sort_keys=True, separators=(",", ":")) + "\n").encode()


def unavailable() -> bytes:
    return (json.dumps({"identifier": IDENTIFIER, "status": "unavailable"},
                       sort_keys=True, separators=(",", ":")) + "\n").encode()
