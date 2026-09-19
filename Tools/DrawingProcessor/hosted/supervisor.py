#!/usr/bin/env python3
"""LOCAL-ONLY one-shot sandbox capability supervisor.

It accepts no source, filename, URL, credential, or processing command. A later
profiled packet may add a bounded processing protocol only after this exact image
passes on the hosted kernel.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys

from protocol import ProbeUnavailable, ReadyProbe, unavailable

MAX_DIAGNOSTIC = 16 * 1024
DEFAULT_LAUNCHER = Path("/opt/snaglist-drawing-hosted/sandbox-launcher")
KILL_DRAIN_TIMEOUT = 1.0


def kill_process_group_and_drain(process: subprocess.Popen[bytes]) -> None:
    """Kill the isolated launcher group and bound pipe/reaping cleanup."""
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        try:
            process.kill()
        except OSError:
            pass
    try:
        process.communicate(timeout=KILL_DRAIN_TIMEOUT)
        return
    except subprocess.TimeoutExpired:
        # A process which escaped the group could retain a pipe. Never wait for it.
        if process.stdout is not None:
            try:
                process.stdout.close()
            except OSError:
                pass
        if process.stderr is not None:
            try:
                process.stderr.close()
            except OSError:
                pass
    except OSError:
        pass
    try:
        process.wait(timeout=KILL_DRAIN_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except OSError:
            pass
        try:
            process.wait(timeout=KILL_DRAIN_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            pass
    except OSError:
        pass


def run_probe(launcher: Path, timeout: float = 30.0) -> ReadyProbe:
    if not launcher.is_absolute() or not launcher.is_file():
        raise ProbeUnavailable("drawing_sandbox_unavailable")
    try:
        process = subprocess.Popen(
            [os.fspath(launcher), "--probe"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True,
            env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC"},
            start_new_session=True,
        )
    except OSError:
        raise ProbeUnavailable("drawing_sandbox_unavailable") from None
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_process_group_and_drain(process)
        raise ProbeUnavailable("drawing_sandbox_unavailable") from None
    if process.returncode != 0 or stderr or len(stdout) > MAX_DIAGNOSTIC:
        raise ProbeUnavailable("drawing_sandbox_unavailable")
    return ReadyProbe.decode(stdout)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--launcher", type=Path, default=DEFAULT_LAUNCHER,
                        help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not args.probe:
        sys.stdout.buffer.write(unavailable())
        return 78
    try:
        result = run_probe(args.launcher)
    except ProbeUnavailable:
        sys.stdout.buffer.write(unavailable())
        return 78
    sys.stdout.buffer.write(result.encode())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
