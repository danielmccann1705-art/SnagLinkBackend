#!/usr/bin/env python3
"""Tests for ad_measurement_report.py against a local RevenueCat API v2 stand-in (127.0.0.1). Standard library only;
no database and no real RevenueCat call. Run: python3 scripts/test_ad_measurement_report.py"""
import contextlib, csv, io, json, os, sys, tempfile, threading, unittest, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ad_measurement_report as report  # noqa: E402

KEY = "sk_synthetic_v2_key_for_tests_only"
SUBSCRIBER = "$RCAnonymousID:0123456789abcdef0123456789abcdef"
CUSTOMER = "7D3C9C3E-0000-4000-8000-00000000000A"
GONE = "$RCAnonymousID:ffffffffffffffffffffffffffffffff"


class Stub(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        Stub.seen.append((self.path, self.headers.get("Authorization")))
        parts = urllib.parse.urlparse(self.path).path.split("/")
        # /v2/projects/<project>/customers/<id>[/subscriptions]
        customer = urllib.parse.unquote(parts[5]) if len(parts) > 5 else ""
        if self.headers.get("Authorization") != "Bearer " + KEY or parts[1:4] != ["v2", "projects", "proj_test"]:
            return self.reply(401, {})
        if customer == GONE:
            return self.reply(404, {"type": "resource_missing"})
        if len(parts) > 6 and parts[6] == "subscriptions":
            return self.reply(200, {"items": [{"id": "sub"}] if customer == SUBSCRIBER else []})
        return self.reply(200, {"id": customer})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ROWS = """rc_app_user_id,exchange_state,attribution,campaign_id,adgroup_id,keyword_id
{sub},done,t,111,222,333
{cus},done,t,111,222,333
{gone},done,t,111,222,
{sub},done,f,,,
{cus},pending,,,,
{cus},failing,,,,
{cus},expired,,,,
{cus},invalid,,,,
""".format(sub=SUBSCRIBER, cus=CUSTOMER, gone=GONE)


class ReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d/v2" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Stub.seen = []
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "outputs" / "ads"
        self.rows = Path(self.tmp.name) / "rows.csv"
        self.rows.write_text(ROWS)
        self.env = {"REVENUECAT_V2_SECRET_KEY": KEY, "REVENUECAT_PROJECT_ID": "proj_test"}

    def tearDown(self):
        self.tmp.cleanup()

    def run_report(self, *extra, env=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = report.main(["--rows", str(self.rows), "--out", str(self.out), "--revenuecat-base", self.base, *extra],
                               environ=self.env if env is None else env)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_aggregates_attributed_records_by_cell_with_blanks_for_withheld_identifiers(self):
        code, stdout, stderr = self.run_report()
        self.assertEqual(code, 0, stderr)
        table = next(self.out.glob("ad-measurement-report-*.csv"))
        with table.open() as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(rows, [
            {"campaign_id": "111", "adgroup_id": "222", "keyword_id": "", "installs": "1", "subscribers": "0", "unresolved": "1"},
            {"campaign_id": "111", "adgroup_id": "222", "keyword_id": "333", "installs": "2", "subscribers": "1", "unresolved": "0"},
        ])
        note = next(self.out.glob("ad-measurement-report-*.txt")).read_text()
        self.assertIn("pending 1, failing 1, done 4, expired 1, invalid 1", note)
        self.assertIn("attributed 3, not attributed 1. Awaiting Apple (pending + failing): 2", note)

    def test_only_api_v2_reads_and_nothing_personal_in_the_output_or_the_console(self):
        code, stdout, stderr = self.run_report()
        self.assertEqual(code, 0, stderr)
        self.assertTrue(all(path.startswith("/v2/projects/proj_test/customers/") for path, _ in Stub.seen))
        self.assertTrue(all(auth == "Bearer " + KEY for _, auth in Stub.seen))
        self.assertEqual(len(Stub.seen), 5, "customer + subscriptions for two known IDs, one 404 for the gone one")
        written = "".join(path.read_text() for path in self.out.iterdir())
        for secret in (SUBSCRIBER, CUSTOMER, GONE, KEY, "0123456789abcdef"):
            self.assertNotIn(secret, written + stdout + stderr)

    def test_refuses_an_output_folder_outside_outputs_and_a_foreign_api_address(self):
        with contextlib.redirect_stderr(io.StringIO()):
            code = report.main(["--rows", str(self.rows), "--out", self.tmp.name + "/elsewhere", "--revenuecat-base", self.base],
                               environ=self.env)
        self.assertEqual(code, 2)
        self.assertFalse((Path(self.tmp.name) / "elsewhere").exists())
        code, _, stderr = self.run_report("--revenuecat-base", "https://api.revenuecat.com/v1")
        self.assertEqual(code, 2)
        self.assertIn("API v2", stderr)
        self.assertEqual(Stub.seen, [])

    def test_requires_the_key_and_project_and_writes_nothing_without_them(self):
        code, _, stderr = self.run_report(env={})
        self.assertEqual(code, 2)
        self.assertNotIn(KEY, stderr)
        self.assertFalse(self.out.exists() and any(self.out.iterdir()))

    def test_a_revenuecat_refusal_writes_no_partial_report(self):
        code, _, stderr = self.run_report(env={"REVENUECAT_V2_SECRET_KEY": "wrong", "REVENUECAT_PROJECT_ID": "proj_test"})
        self.assertEqual(code, 2)
        self.assertIn("no report was written", stderr)
        self.assertFalse(any(self.out.glob("*.csv")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
