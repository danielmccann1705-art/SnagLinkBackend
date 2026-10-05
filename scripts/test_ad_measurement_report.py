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
GRACE = "$RCAnonymousID:11111111111111111111111111111111"
LAPSED = "$RCAnonymousID:22222222222222222222222222222222"
SANDBOX = "$RCAnonymousID:33333333333333333333333333333333"
TRIAL = "$RCAnonymousID:44444444444444444444444444444444"
PAGED = "$RCAnonymousID:55555555555555555555555555555555"
TESTER = "$RCAnonymousID:66666666666666666666666666666666"
TESTER2 = "7D3C9C3E-0000-4000-8000-00000000000B"


def sub(environment, status, gross):
    return {"object": "subscription", "id": "sub_" + status, "environment": environment, "status": status,
            "gives_access": status in ("trialing", "active", "in_grace_period"),
            "total_revenue_in_usd": {"currency": "USD", "gross": gross, "commission": 0, "tax": 0, "proceeds": gross}}


# Pages of subscriptions per customer, as API v2 lists them; a customer not named here has none.
SUBSCRIPTIONS = {
    SUBSCRIBER: [[sub("production", "active", 9.99)]],
    GRACE: [[sub("production", "in_grace_period", 9.99)]],
    LAPSED: [[sub("production", "expired", 4.99)]],
    SANDBOX: [[sub("sandbox", "active", 9.99), sub("sandbox", "expired", 9.99)]],
    TRIAL: [[sub("production", "trialing", 0), sub("production", "expired", 0)]],
    PAGED: [[sub("sandbox", "active", 9.99)], [sub("production", "active", 9.99)]],
    TESTER: [[sub("sandbox", "active", 9.99), sub("production", "active", 9.99)]],
    TESTER2: [[sub("production", "active", 9.99)]],
}


class Stub(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        Stub.seen.append((self.path, self.headers.get("Authorization")))
        url = urllib.parse.urlparse(self.path)
        parts, query = url.path.split("/"), urllib.parse.parse_qs(url.query)
        # /v2/projects/<project>/customers/<id>[/subscriptions?limit=..[&starting_after=page-N]]
        customer = urllib.parse.unquote(parts[5]) if len(parts) > 5 else ""
        if self.headers.get("Authorization") != "Bearer " + KEY or parts[1:4] != ["v2", "projects", "proj_test"]:
            return self.reply(401, {})
        if customer == GONE:
            return self.reply(404, {"type": "resource_missing"})
        if len(parts) > 6 and parts[6] == "subscriptions":
            pages = SUBSCRIPTIONS.get(customer, [[]])
            page = int(query.get("starting_after", ["page-0"])[0].split("-")[1])
            following = None
            if page + 1 < len(pages):
                following = "/v2/projects/proj_test/customers/%s/subscriptions?starting_after=page-%d&limit=100" % (
                    urllib.parse.quote(customer, safe=""), page + 1)
            return self.reply(200, {"object": "list", "items": pages[page], "next_page": following, "url": url.path})
        return self.reply(200, {"object": "customer", "id": customer})

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
            {"campaign_id": "111", "adgroup_id": "222", "keyword_id": "", "installs": "1", "paying_now": "0", "ever_paid": "0",
             "unresolved": "1"},
            {"campaign_id": "111", "adgroup_id": "222", "keyword_id": "333", "installs": "2", "paying_now": "1", "ever_paid": "1",
             "unresolved": "0"},
        ])
        note = next(self.out.glob("ad-measurement-report-*.txt")).read_text()
        self.assertIn("pending 1, failing 1, done 4, expired 1, invalid 1", note)
        self.assertIn("attributed 3, placeholder 0, not attributed 1. Awaiting Apple (pending + failing): 2", note)

    def report_rows(self):
        with next(self.out.glob("ad-measurement-report-*.csv")).open() as handle:
            return list(csv.DictReader(handle))

    def test_apples_placeholder_record_is_counted_apart_never_as_an_install_or_a_subscriber(self):
        # M1: Xcode / TestFlight installs get Apple's test record (campaign and ad group 1234567890). The testers here
        # hold production subscriptions in the stub, so counting them would show up as installs and paying customers.
        self.rows.write_text("\n".join([
            "rc_app_user_id,exchange_state,attribution,campaign_id,adgroup_id,keyword_id",
            "%s,done,t,1234567890,1234567890,12323222" % TESTER,     # the commonly observed form
            "%s,done,t,1234567890,1234567890,123222" % TESTER2,      # the form in the Sept 2026 document
            "%s,done,t,1234567890,1234567890," % SUBSCRIBER,         # keyword withheld: still the placeholder
            "%s,done,t,1234567890,555,333" % SUBSCRIBER,             # campaign alone matching: a real record
            ""]))
        code, stdout, stderr = self.run_report()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(self.report_rows(), [
            {"campaign_id": "1234567890", "adgroup_id": "555", "keyword_id": "333", "installs": "1", "paying_now": "1",
             "ever_paid": "1", "unresolved": "0"},
        ])
        note = next(self.out.glob("ad-measurement-report-*.txt")).read_text()
        self.assertIn("done 4,", note)
        self.assertIn("attributed 1, placeholder 3, not attributed 0.", note)
        self.assertIn("never an install or a subscriber", note)
        self.assertIn("3 placeholder", stdout)
        asked = [path for path, _ in Stub.seen]
        self.assertEqual(len(asked), 2, "customer + subscriptions for the one real record only")
        for tester in (TESTER, TESTER2):
            self.assertFalse(any(urllib.parse.quote(tester, safe="") in path for path in asked), "RevenueCat asked about a tester")

    def test_paying_now_and_ever_paid_count_production_subscriptions_only(self):
        # M2: sandbox subscriptions (TestFlight, Xcode, StoreKit testing) and a free trial alone are neither; an expired
        # production subscription with revenue is ever_paid only; every page of subscriptions is read.
        self.rows.write_text("\n".join(
            ["rc_app_user_id,exchange_state,attribution,campaign_id,adgroup_id,keyword_id"]
            + ["%s,done,t,7,8,9" % customer for customer in (SUBSCRIBER, GRACE, LAPSED, SANDBOX, TRIAL, PAGED, CUSTOMER, GONE)]
            + [""]))
        code, stdout, stderr = self.run_report()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(self.report_rows(), [
            {"campaign_id": "7", "adgroup_id": "8", "keyword_id": "9", "installs": "8", "paying_now": "3", "ever_paid": "4",
             "unresolved": "1"},
        ])
        asked = [path for path, _ in Stub.seen]
        self.assertTrue(all("limit=100" in path for path in asked if "/subscriptions" in path))
        paged = urllib.parse.quote(PAGED, safe="")
        self.assertEqual(sum(1 for path in asked if paged in path and "/subscriptions" in path), 2, "both pages read")
        self.assertTrue(any(paged in path and "starting_after=page-1" in path for path in asked))
        note = next(self.out.glob("ad-measurement-report-*.txt")).read_text()
        self.assertIn("Sandbox subscriptions (TestFlight, Xcode, StoreKit testing) count in neither", note)

    def test_rows_without_the_query_columns_are_refused_before_any_request(self):
        self.rows.write_text("rc_app_user_id,exchange_state,attribution,campaign_id,keyword_id\n%s,done,t,1,2\n" % SUBSCRIBER)
        code, _, stderr = self.run_report()
        self.assertEqual(code, 2)
        self.assertIn("adgroup_id", stderr)
        self.assertIn("ROWS_QUERY", stderr)
        self.assertEqual(Stub.seen, [])
        self.assertFalse(any(self.out.glob("*.csv")))

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
