import json
import unittest

from protocol import (IDENTIFIER, REQUIRED_CHECKS, SCHEMA, SCRATCH_BYTES,
                      SCRATCH_INODES, ProbeUnavailable, ReadyProbe, unavailable)


def ready_value():
    return {
        "schema": SCHEMA, "status": "ready", "scratchBytes": SCRATCH_BYTES,
        "scratchInodes": SCRATCH_INODES, "checks": list(REQUIRED_CHECKS),
    }


class ProbeProtocolTests(unittest.TestCase):
    def test_exact_ready_evidence_round_trips(self):
        decoded = ReadyProbe.decode(json.dumps(ready_value()).encode())
        self.assertEqual(decoded.checks, REQUIRED_CHECKS)
        self.assertEqual(ReadyProbe.decode(decoded.encode()), decoded)

    def test_missing_reordered_duplicate_and_unknown_checks_fail_closed(self):
        for checks in (list(REQUIRED_CHECKS[:-1]), list(reversed(REQUIRED_CHECKS)),
                       list(REQUIRED_CHECKS) + [REQUIRED_CHECKS[-1]],
                       list(REQUIRED_CHECKS) + ["claimed_without_probe"]):
            value = ready_value(); value["checks"] = checks
            with self.subTest(checks=checks), self.assertRaises(ProbeUnavailable):
                ReadyProbe.decode(json.dumps(value).encode())

    def test_extra_fields_wrong_bounds_and_oversize_fail_closed(self):
        extra = ready_value(); extra["diagnostic"] = "not part of evidence"
        wrong = ready_value(); wrong["scratchBytes"] -= 1
        for raw in (json.dumps(extra).encode(), json.dumps(wrong).encode(), b"x" * (16 * 1024 + 1)):
            with self.assertRaises(ProbeUnavailable): ReadyProbe.decode(raw)

    def test_unavailable_is_small_and_has_no_kernel_diagnostic(self):
        value = json.loads(unavailable())
        self.assertEqual(value, {"identifier": IDENTIFIER, "status": "unavailable"})


if __name__ == "__main__": unittest.main()
