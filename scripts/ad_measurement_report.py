#!/usr/bin/env python3
"""Snaglist 2.0.2 advert-measurement report (IOS-2.0.2-SLICE1.md item 17; MEASUREMENT-DECISION.md §3.4 "Reporting").

Run by a person, read-only, nothing written back anywhere. For every `ad_attribution_records` row that Apple
attributed (`exchange_state = 'done' AND attribution = true`), RevenueCat REST API v2 is asked whether the customer
the row names still exists and has any subscription; the answer is aggregated by campaign / ad group / keyword:

    campaign_id, adgroup_id, keyword_id, installs, subscribers, unresolved

* installs     attributed records in the cell (one per consenting installation; refusals are not in any denominator)
* subscribers  of those, customers with at least one subscription in RevenueCat
* unresolved   customers RevenueCat no longer knows (API v2 answers 404: deleted, or never created)
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
"""
import argparse, csv, io, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROWS_QUERY = ("SELECT rc_app_user_id, exchange_state, attribution, campaign_id, adgroup_id, keyword_id "
              "FROM ad_attribution_records ORDER BY created_at")
REVENUECAT_V2 = "https://api.revenuecat.com/v2"
STATES = ("pending", "failing", "done", "expired", "invalid")
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
    return list(csv.DictReader(io.StringIO(text)))


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
        """'subscriber', 'customer' (no subscription) or 'unresolved' (404)."""
        quoted = urllib.parse.quote(customer_id, safe="")
        code, _ = self._get("customers/" + quoted)
        if code == 404:
            return "unresolved"
        code, body = self._get("customers/" + quoted + "/subscriptions?limit=1")
        if code == 404:
            return "unresolved"
        return "subscriber" if (body or {}).get("items") else "customer"


def build(rows, revenuecat):
    summary = {state: 0 for state in STATES}
    summary.update(attributed=0, not_attributed=0)
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
        summary["attributed"] += 1
        key = tuple((row.get(column) or "").strip() for column in ("campaign_id", "adgroup_id", "keyword_id"))
        cell = cells.setdefault(key, {"installs": 0, "subscribers": 0, "unresolved": 0})
        cell["installs"] += 1
        customer = (row.get("rc_app_user_id") or "").strip()
        if customer not in cache:
            cache[customer] = revenuecat.status(customer) if customer else "unresolved"
        if cache[customer] == "subscriber":
            cell["subscribers"] += 1
        elif cache[customer] == "unresolved":
            cell["unresolved"] += 1
    return cells, summary


def write(out, cells, summary, now):
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    table = out / ("ad-measurement-report-%s.csv" % stamp)
    with table.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["campaign_id", "adgroup_id", "keyword_id", "installs", "subscribers", "unresolved"])
        for key in sorted(cells):
            cell = cells[key]
            writer.writerow(list(key) + [cell["installs"], cell["subscribers"], cell["unresolved"]])
    note = out / ("ad-measurement-report-%s.txt" % stamp)
    note.write_text("\n".join([
        "Snaglist advert-measurement report, %s (read-only; RevenueCat API v2)." % now.isoformat(timespec="seconds"),
        "Records by exchange state: " + ", ".join("%s %d" % (state, summary[state]) for state in STATES) + ".",
        "Done: attributed %d, not attributed %d. Awaiting Apple (pending + failing): %d - not counted as not attributed."
        % (summary["attributed"], summary["not_attributed"], summary["pending"] + summary["failing"]),
        "Only installations that agreed to measurement are here; refusals are in no denominator.",
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
    print("wrote %s and %s (%d cells, %d attributed records, %d RevenueCat requests)"
          % (table, note, len(cells), summary["attributed"], revenuecat.requests))
    return 0


if __name__ == "__main__":
    sys.exit(main())
