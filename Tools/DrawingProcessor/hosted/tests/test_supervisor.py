import json
import os
from pathlib import Path
import tempfile
import time
import unittest

from protocol import REQUIRED_CHECKS, SCHEMA, SCRATCH_BYTES, SCRATCH_INODES, ProbeUnavailable
from supervisor import run_probe


class SupervisorTests(unittest.TestCase):
    def launcher(self, body: str, status: int = 0) -> Path:
        directory = tempfile.TemporaryDirectory(prefix="drawing-probe-")
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "launcher"
        payload = body.replace("'", "'\\''")
        path.write_text(f"#!/bin/sh\nprintf '%s' '{payload}'\nexit {status}\n")
        path.chmod(0o700)
        return path

    def ready(self) -> str:
        return json.dumps({"schema": SCHEMA, "status": "ready", "scratchBytes": SCRATCH_BYTES,
                           "scratchInodes": SCRATCH_INODES, "checks": list(REQUIRED_CHECKS)})

    def test_only_exact_success_is_accepted(self):
        result = run_probe(self.launcher(self.ready()))
        self.assertEqual(result.checks, REQUIRED_CHECKS)

    def test_nonzero_malformed_and_false_ready_are_unavailable(self):
        false_ready = json.loads(self.ready()); false_ready["checks"].remove("network_denied")
        cases = ((self.ready(), 78), ("not-json", 0), (json.dumps(false_ready), 0))
        for body, status in cases:
            with self.subTest(status=status), self.assertRaises(ProbeUnavailable):
                run_probe(self.launcher(body, status))

    def test_stderr_or_oversized_stdout_is_unavailable(self):
        noisy = self.launcher(self.ready())
        noisy.write_text(noisy.read_text().replace("exit 0", "printf warning >&2\nexit 0"))
        with self.assertRaises(ProbeUnavailable):
            run_probe(noisy)
        with self.assertRaises(ProbeUnavailable):
            run_probe(self.launcher("x" * (16 * 1024 + 1)))

    def test_relative_or_missing_launcher_is_unavailable(self):
        for path in (Path("relative"), Path("/definitely/missing/sandbox-launcher")):
            with self.assertRaises(ProbeUnavailable): run_probe(path)

    def test_timeout_kills_descendants_and_does_not_wait_on_their_pipes(self):
        launcher = self.launcher("")
        directory = launcher.parent
        started_marker = directory / "descendant-started"
        survived = directory / "descendant-survived"
        launcher.write_text(
            "#!/bin/sh\n"
            f"(/usr/bin/touch '{started_marker}'; /bin/sleep 0.8; /usr/bin/touch '{survived}') &\n"
            "/bin/sleep 30\n"
        )
        started_at = time.monotonic()
        with self.assertRaises(ProbeUnavailable):
            run_probe(launcher, timeout=0.3)
        elapsed = time.monotonic() - started_at
        self.assertLess(elapsed, 1.5)
        self.assertTrue(started_marker.is_file())
        time.sleep(0.8)
        self.assertFalse(survived.exists())


if __name__ == "__main__": unittest.main()
