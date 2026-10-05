#!/usr/bin/env python3
"""Snaglist 2.0.2 advert-measurement report (IOS-2.0.2-SLICE1.md item 17; MEASUREMENT-DECISION.md §3.4 "Reporting").

Run by a person, read-only, nothing written back anywhere. For every `ad_attribution_records` row that Apple
attributed (`exchange_state = 'done' AND attribution = true`), RevenueCat REST API v2 is asked whether the customer
the row names still exists and which subscriptions it has; the answer is aggregated by campaign / ad group / keyword:

    campaign_id, adgroup_id, keyword_id, installs, paying_now, ever_paid, unresolved

* installs     attributed records in the cell (one per consenting installation; refusals are not in any denominator)
* paying_now   of those, customers with a production subscription whose RevenueCat status is `active` or
               `in_grace_period` now
* ever_paid    of those, customers with a production subscription that is paying now or for which RevenueCat reports
               revenue (`total_revenue_in_usd.gross` > 0)
               Only `environment = "production"` subscriptions count: sandbox ones (TestFlight, Xcode, StoreKit testing)
               never do, and a free trial alone (`trialing`, no revenue) is neither.
* unresolved   customers RevenueCat no longer knows (API v2 answers 404: deleted, or never created)
* placeholder  Apple's test record (developer mode; what Xcode and TestFlight installs receive), recognised by campaign
               and ad group both being 1234567890, is counted apart in the summary - never an install, a paying or an
               unresolved customer - and RevenueCat is not asked about it (EVENT-CONTRACT.md rule 4)
* An identifier Apple withheld is a blank cell, never 0. Records still waiting for Apple are counted in the summary
  as awaiting, never as "not attributed".

API v2 only: `GET /v2/projects/{project}/customers/{id}` answers 404 for an unknown customer and never creates one
(v1 `GET /subscribers/{id}` creates one and must not be used). Output goes only to a directory with a path
component named `outputs`, and holds counts and campaign identifiers only - no app user ID, reference or token.

Configuration (environment only; nothing is printed):
  REVENUECAT_V2_SECRET_KEY   a RevenueCat v2 secret key with read access to customers (the backend's v1 key is not one)
  REVENUECAT_PROJECT_ID      the RevenueCat project ID
  AD_REPORT_DATABASE_URL     postgresql://... for the read (a read-only role is best); the session is also set
                             read-only. Not needed with --rows.

Usage:
  scripts/ad_measurement_report.py --out <.../outputs/...>
  scripts/ad_measurement_report.py --rows rows.csv --out <.../outputs/...>   # rows exported with ROWS_QUERY below
A --rows file is a list of customer IDs held outside the database: delete it after the run, or prefer the read-only
database session.
"""
import argparse, csv, io, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROWS_QUERY = ("SELECT rc_app_user_id, exchange_state, attribution, campaign_id, adgroup_id, keyword_id "
              "FROM ad_attribution_records ORDER BY created_at")
REVENUECAT_V2 = "https://api.revenuecat.com/v2"
REQUIRED_COLUMNS = ("rc_app_user_id", "exchange_state", "attribution", "campaign_id", "adgroup_id", "keyword_id")
STATES = ("pending", "failing", "done", "expired", "invalid")
# Apple's test attribution record (AdServices API: returned while the app is in developer mode, which is what Xcode
# and TestFlight installs receive). Campaign and ad group are both 1234567890 in every published form of it; the
# keyword and ad identifiers differ between forms (12323222 / 1234567890 as commonly observed; 123222 / 542317136 in
# the Sept 2026 AdServices API v4 document), so they are not part of the test. A real campaign and its ad group never
# share one identifier. Confirm against the staging case-B3 row (FABLE-REVIEW-2.0.2-BACKEND.md M1).
PLACEHOLDER = (("campaign_id", "1234567890"), ("adgroup_id", "1234567890"))
PAYING_STATUSES = ("active", "in_grace_period")
SUBSCRIPTION_PAGE = 100       # API v2 maximum
MAX_SUBSCRIPTION_PAGES = 20
PAUSE_SECONDS = 0.15          # about 400 requests a minute, under the API v2 customer limit of 480
MAX_RETRIES = 3


class ReportError(Exception):
    pass


def output_directory(raw):
    path = Path(raw).expanduser().resolve()
    if "outputs" not in path.parts:
        raise ReportError("--out must be inside a folder named 'outputs'")
    path.mkdir(parents=True, exist_ok=True)
    return path


def revenuecat_base(raw):
    if raw == REVENUECAT_V2:
        return raw
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme == "http" and parsed.hostname == "127.0.0.1":   # the local test stub only
        return raw.rstrip("/")
    raise ReportError("--revenuecat-base must be the RevenueCat API v2 address")


def rows_from_csv(text):
    reader = csv.DictReader(io.StringIO(text))
    missing = [column for column in REQUIRED_COLUMNS if column not in (reader.fieldnames or [])]
    if missing:
        raise ReportError("the rows lack %s; export them with ROWS_QUERY" % ", ".join(missing))
    return list(reader)


def rows_from_database(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname or not parsed.path.strip("/"):
        raise ReportError("AD_REPORT_DATABASE_URL must be a postgresql:// address with a database name")
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "PGHOST": parsed.hostname, "PGPORT": str(parsed.port or 5432),
           "PGUSER": urllib.parse.unquote(parsed.username or ""), "PGPASSWORD": urllib.parse.unquote(parsed.password or ""),
           "PGDATABASE": parsed.path.strip("/"), "PGOPTIONS": "-c default_transaction_read_only=on",
           "PGSSLMODE": urllib.parse.parse_qs(parsed.query).get("sslmode", ["prefer"])[0]}
    result = subprocess.run(["psql", "-X", "--csv", "-v", "ON_ERROR_STOP=1", "-c", ROWS_QUERY],
                            env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise ReportError("the database read failed (psql exit %d)" % result.returncode)
    return rows_from_csv(result.stdout)


def truthy(value):
    return str(value).strip().lower() in ("t", "true", "1")


def is_placeholder(row):
    return all((row.get(column) or "").strip() == value for column, value in PLACEHOLDER)


def gross_revenue(subscription):
    revenue = subscription.get("total_revenue_in_usd")
    try:
        return float(revenue.get("gross") or 0) if isinstance(revenue, dict) else 0.0
    except (TypeError, ValueError):
        return 0.0


def next_cursor(next_page):
    if not next_page:
        return None
    values = urllib.parse.parse_qs(urllib.parse.urlparse(str(next_page)).query).get("starting_after") or [""]
    if not values[0]:
        raise ReportError("RevenueCat's next page could not be read; no report was written")
    return values[0]


class RevenueCat:
    def __init__(self, base, project, key, pause=PAUSE_SECONDS):
        self.base, self.project, self.key, self.pause = base, project, key, pause
        self.requests = 0

    def _get(self, path):
        url = "%s/projects/%s/%s" % (self.base, urllib.parse.quote(self.project, safe=""), path)
        for attempt in range(MAX_RETRIES + 1):
            if self.requests:
                time.sleep(self.pause)
            self.requests += 1
            request = urllib.request.Request(url, headers={"Authorization": "Bearer " + self.key, "Accept": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    return 200, json.loads(response.read() or b"{}")
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return 404, None
                if error.code in (429, 500, 502, 503, 504) and attempt < MAX_RETRIES:
                    try:
                        wait = min(60, int(error.headers.get("Retry-After") or 2))
                    except ValueError:
                        wait = 2
                    time.sleep(wait if error.code == 429 else 2)
                    continue
                raise ReportError("RevenueCat answered %d; no report was written" % error.code)
            except (urllib.error.URLError, TimeoutError, ValueError):
                if attempt < MAX_RETRIES:
                    time.sleep(2)
                    continue
                raise ReportError("RevenueCat could not be reached; no report was written")
        raise ReportError("RevenueCat kept refusing; no report was written")

    def status(self, customer_id):
        """'paying_now', 'ever_paid', 'customer' (no paid production subscription) or 'unresolved' (404)."""
        quoted = urllib.parse.quote(customer_id, safe="")
        code, _ = self._get("customers/" + quoted)
        if code == 404:
            return "unresolved"
        paying_now = ever_paid = False
        query = "limit=%d" % SUBSCRIPTION_PAGE
        for _ in range(MAX_SUBSCRIPTION_PAGES):
            code, body = self._get("customers/%s/subscriptions?%s" % (quoted, query))
            if code == 404:
                return "unresolved"
            body = body if isinstance(body, dict) else {}
            for subscription in body.get("items") or []:
                if not isinstance(subscription, dict) or subscription.get("environment") != "production":
                    continue
                if subscription.get("status") in PAYING_STATUSES:
                    paying_now = ever_paid = True
                elif gross_revenue(subscription) > 0:
                    ever_paid = True
            cursor = next_cursor(body.get("next_page"))
            if not cursor:
                break
            query = "limit=%d&starting_after=%s" % (SUBSCRIPTION_PAGE, urllib.parse.quote(cursor, safe=""))
        else:
            raise ReportError("RevenueCat listed more subscriptions than expected; no report was written")
        return "paying_now" if paying_now else "ever_paid" if ever_paid else "customer"


def build(rows, revenuecat):
    summary = {state: 0 for state in STATES}
    summary.update(attributed=0, placeholder=0, not_attributed=0)
    cells, cache = {}, {}
    for row in rows:
        state = (row.get("exchange_state") or "").strip()
        if state in summary:
            summary[state] += 1
        if state != "done":
            continue
        if not truthy(row.get("attribution")):
            summary["not_attributed"] += 1
            continue
        if is_placeholder(row):
            summary["placeholder"] += 1
            continue
        summary["attributed"] += 1
        key = tuple((row.get(column) or "").strip() for column in ("campaign_id", "adgroup_id", "keyword_id"))
        cell = cells.setdefault(key, {"installs": 0, "paying_now": 0, "ever_paid": 0, "unresolved": 0})
        cell["installs"] += 1
        customer = (row.get("rc_app_user_id") or "").strip()
        if customer not in cache:
            cache[customer] = revenuecat.status(customer) if customer else "unresolved"
        if cache[customer] in ("paying_now", "ever_paid"):
            cell["ever_paid"] += 1
            cell["paying_now"] += cache[customer] == "paying_now"
        elif cache[customer] == "unresolved":
            cell["unresolved"] += 1
    return cells, summary


def write(out, cells, summary, now):
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    table = out / ("ad-measurement-report-%s.csv" % stamp)
    with table.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["campaign_id", "adgroup_id", "keyword_id", "installs", "paying_now", "ever_paid", "unresolved"])
        for key in sorted(cells):
            cell = cells[key]
            writer.writerow(list(key) + [cell["installs"], cell["paying_now"], cell["ever_paid"], cell["unresolved"]])
    note = out / ("ad-measurement-report-%s.txt" % stamp)
    note.write_text("\n".join([
        "Snaglist advert-measurement report, %s (read-only; RevenueCat API v2)." % now.isoformat(timespec="seconds"),
        "Records by exchange state: " + ", ".join("%s %d" % (state, summary[state]) for state in STATES) + ".",
        "Done: attributed %d, placeholder %d, not attributed %d. Awaiting Apple (pending + failing): %d - not counted as not attributed."
        % (summary["attributed"], summary["placeholder"], summary["not_attributed"], summary["pending"] + summary["failing"]),
        "Placeholder = Apple's test record (developer mode: Xcode and TestFlight installs; campaign and ad group 1234567890):"
        " never an install or a subscriber, and RevenueCat was not asked about it.",
        "Only installations that agreed to measurement are here; refusals are in no denominator.",
        "paying_now = the customer has a production subscription RevenueCat shows as active or in a grace period now;"
        " ever_paid = a production subscription that is paying now or has RevenueCat revenue. Sandbox subscriptions"
        " (TestFlight, Xcode, StoreKit testing) count in neither, nor does a free trial alone.",
        "Blank identifier cells were withheld by Apple, not zero. Unresolved = RevenueCat no longer knows the customer.",
        ""]))
    return table, note


def main(argv=None, environ=None):
    environ = os.environ if environ is None else environ
    parser = argparse.ArgumentParser(description="Snaglist 2.0.2 advert-measurement report (read-only).")
    parser.add_argument("--out", required=True)
    parser.add_argument("--rows", help="a CSV exported with ROWS_QUERY, instead of reading the database")
    parser.add_argument("--revenuecat-base", default=REVENUECAT_V2)
    args = parser.parse_args(argv)
    try:
        out = output_directory(args.out)
        base = revenuecat_base(args.revenuecat_base)
        key, project = environ.get("REVENUECAT_V2_SECRET_KEY", "").strip(), environ.get("REVENUECAT_PROJECT_ID", "").strip()
        if not key or not project:
            raise ReportError("REVENUECAT_V2_SECRET_KEY and REVENUECAT_PROJECT_ID are required")
        if args.rows:
            rows = rows_from_csv(Path(args.rows).read_text())
        else:
            url = environ.get("AD_REPORT_DATABASE_URL", "")
            if not url:
                raise ReportError("AD_REPORT_DATABASE_URL is required without --rows")
            rows = rows_from_database(url)
        revenuecat = RevenueCat(base, project, key, pause=0 if base != REVENUECAT_V2 else PAUSE_SECONDS)
        cells, summary = build(rows, revenuecat)
        table, note = write(out, cells, summary, datetime.now(timezone.utc))
    except ReportError as error:
        print("ad_measurement_report: " + str(error), file=sys.stderr)
        return 2
    print("wrote %s and %s (%d cells, %d attributed records, %d placeholder, %d RevenueCat requests)"
          % (table, note, len(cells), summary["attributed"], summary["placeholder"], revenuecat.requests))
    return 0


if __name__ == "__main__":
    sys.exit(main())
