#!/usr/bin/env python3
"""Local fake PostHog for the L7 harness dry run (loopback only, synthetic keys only).

It reproduces the PostHog semantics documented in POSTHOG-DELAYED-INGESTION-OCT9.md
(PostHog source 548a133, read on 9 October 2026), with wall-clock timers so the harness
drives it exactly as it would drive the real sandbox:

- Capture acceptance precedes storage: an accepted capture is written --ingest-lag
  seconds later. A written event attaches to the distinct ID's current person (queued
  for deletion or not); with no person, one is created whose UUID is derived from the
  distinct ID ("person_id is deterministic"). An event sent with
  $process_person_profile=false gets that derived person_id but no person row.
- bulk_delete queues each found person for removal (after --person-removal-delay) and
  creates ONE event deletion per person UUID ((deletion_type, key) unique,
  ignore_conflicts). A re-issued deletion still answers 202 with
  events_queued_for_deletion=true, and the status endpoint keeps returning the
  original row (same created_at).
- An event deletion runs --deletion-delay seconds after its row was created and removes
  only rows with person_id = uuid AND written_at <= created_at; then delete_verified_at
  is set. Rows written after the request survive.
- Query API: HogQL count() of events by distinct_id, any person, any write time,
  is_cached false; 403 with --no-query-scope.
- Auth: the Bearer key must equal the synthetic personal key and capture api_key the
  synthetic project token. Another project is 403; any other path is 404.

The request log records method, path, query and status only: never headers or bodies.
"""
import argparse
import json
import re
import signal
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PROJECT = "298161"
NAMESPACE = uuid.UUID("6f1c2b4e-5a17-4c0d-9e57-da7a5afe0001")
COUNT_RE = re.compile(r"^SELECT count\(\) FROM events WHERE distinct_id = '([0-9a-f-]{36})'$")
PERSONS_RE = re.compile(
    r"^SELECT count\(\), groupUniqArray\(toString\(person_id\)\) FROM events WHERE distinct_id = '([0-9a-f-]{36})'$")


def iso(t):
    return datetime.fromtimestamp(t, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class FakePostHog:
    def __init__(self, api_key, project_token, ingest_lag=1.0, person_removal_delay=1.5, deletion_delay=3.0,
                 query_scope=True, clock=time.time):
        self.api_key = api_key
        self.project_token = project_token
        self.ingest_lag = ingest_lag
        self.person_removal_delay = person_removal_delay
        self.deletion_delay = deletion_delay
        self.query_scope = query_scope
        self.clock = clock
        self.lock = threading.RLock()
        self.accepted = []   # {distinct_id, accepted_at, profile, event, uuid}
        self.events = []     # {distinct_id, person_id, written_at, event, uuid}
        self.persons = {}    # distinct_id -> {uuid, created_at, queued_at}
        self.deletions = {}  # person uuid -> {created_at, verified_at}

    @staticmethod
    def derived(distinct_id):
        return str(uuid.uuid5(NAMESPACE, f"{PROJECT}:{distinct_id}"))

    def tick(self):
        """Apply every timer that is due, in time order, each at its own due time."""
        now = self.clock()
        while True:
            due = []
            for index, capture in enumerate(self.accepted):
                due.append((capture["accepted_at"] + self.ingest_lag, 0, "ingest", index))
            for distinct_id, person in self.persons.items():
                if person["queued_at"] is not None:
                    due.append((person["queued_at"] + self.person_removal_delay, 1, "remove", distinct_id))
            for person_uuid, deletion in self.deletions.items():
                if deletion["verified_at"] is None:
                    due.append((deletion["created_at"] + self.deletion_delay, 2, "delete", person_uuid))
            due = [item for item in due if item[0] <= now]
            if not due:
                return
            at, _, kind, key = min(due, key=lambda item: (item[0], item[1]))
            if kind == "ingest":
                capture = self.accepted.pop(key)
                distinct_id = capture["distinct_id"]
                if capture["profile"]:
                    person = self.persons.get(distinct_id)
                    if person is None:
                        person = {"uuid": self.derived(distinct_id), "created_at": at, "queued_at": None}
                        self.persons[distinct_id] = person
                    person_id = person["uuid"]
                else:
                    person_id = self.derived(distinct_id)
                self.events.append({"distinct_id": distinct_id, "person_id": person_id, "written_at": at,
                                    "event": capture["event"], "uuid": capture["uuid"]})
            elif kind == "remove":
                del self.persons[key]
            else:
                deletion = self.deletions[key]
                self.events = [e for e in self.events
                               if not (e["person_id"] == key and e["written_at"] <= deletion["created_at"])]
                deletion["verified_at"] = at

    def handle(self, method, raw_path, headers, body):
        """Returns (status, JSON object). `headers` keys are lower-case."""
        with self.lock:
            self.tick()
            parts = urlsplit(raw_path)
            path, query = parts.path, parse_qs(parts.query)
            if method == "POST" and path == "/capture/":
                return self.capture(body)
            match = re.match(r"^/api/projects/([0-9]+)/(.*)$", path)
            if not match:
                return 404, {"detail": "Not found."}
            if headers.get("authorization") != f"Bearer {self.api_key}":
                return 401, {"type": "authentication_error", "detail": "Invalid personal API key."}
            if match.group(1) != PROJECT:
                return 403, {"detail": "You don't have access to the project."}
            rest = match.group(2)
            if method == "GET" and rest == "persons/":
                return self.persons_list(query)
            if method == "POST" and rest == "persons/bulk_delete/":
                return self.bulk_delete(body)
            if method == "GET" and rest == "persons/deletion_status/":
                return self.deletion_status(query)
            if method == "POST" and rest == "query/":
                return self.run_query(body)
            return 404, {"detail": "Not found."}

    def capture(self, body):
        try:
            payload = json.loads(body or b"{}")
        except ValueError:
            return 400, {"detail": "invalid JSON"}
        if payload.get("api_key") != self.project_token:
            return 401, {"type": "authentication_error", "detail": "Project API key invalid."}
        properties = payload.get("properties") or {}
        distinct_id = properties.get("distinct_id") or payload.get("distinct_id")
        if not isinstance(distinct_id, str) or not distinct_id:
            return 400, {"detail": "distinct_id required"}
        self.accepted.append({"distinct_id": distinct_id, "accepted_at": self.clock(),
                              "profile": properties.get("$process_person_profile", True) is not False,
                              "event": payload.get("event"), "uuid": payload.get("uuid")})
        return 200, {"status": "Ok"}

    def person_row(self, distinct_id, person):
        return {"uuid": person["uuid"], "distinct_ids": [distinct_id], "properties": {},
                "created_at": iso(person["created_at"])}

    def persons_list(self, query):
        distinct_id = (query.get("distinct_id") or [None])[0]
        rows = [self.person_row(d, p) for d, p in self.persons.items() if d == distinct_id]
        return 200, {"next": None, "previous": None, "results": rows}

    def bulk_delete(self, body):
        try:
            payload = json.loads(body or b"{}")
        except ValueError:
            return 400, {"detail": "invalid JSON"}
        ids = payload.get("distinct_ids") or []
        delete_events = payload.get("delete_events") is True
        now = self.clock()
        found = [(d, p) for d, p in self.persons.items() if d in ids]
        for _, person in found:
            if person["queued_at"] is None:
                person["queued_at"] = now
            # One event deletion per person UUID: a repeat queues nothing new.
            if delete_events and person["uuid"] not in self.deletions:
                self.deletions[person["uuid"]] = {"created_at": now, "verified_at": None}
        return 202, {"persons_found": len(found), "persons_deleted": 0,
                     "persons_queued_for_deletion": len(found),
                     "events_queued_for_deletion": bool(found) and delete_events,
                     "recordings_queued_for_deletion": False, "deletion_errors": []}

    def deletion_status(self, query):
        person_uuid = (query.get("person_uuid") or [None])[0]
        rows = []
        deletion = self.deletions.get(person_uuid)
        if deletion is not None:
            rows.append({"person_uuid": person_uuid, "created_at": iso(deletion["created_at"]),
                         "status": "completed" if deletion["verified_at"] is not None else "pending",
                         "delete_verified_at": iso(deletion["verified_at"]) if deletion["verified_at"] else None})
        return 200, {"next": None, "previous": None, "results": rows}

    def run_query(self, body):
        if not self.query_scope:
            return 403, {"detail": "API key missing required scope 'query:read'"}
        try:
            payload = json.loads(body or b"{}")
        except ValueError:
            return 400, {"detail": "invalid JSON"}
        query = payload.get("query") or {}
        if query.get("kind") != "HogQLQuery" or payload.get("refresh") != "force_blocking":
            return 400, {"detail": "the fake answers only force_blocking HogQL queries"}
        text = query.get("query") or ""
        count = COUNT_RE.match(text)
        if count:
            n = sum(1 for e in self.events if e["distinct_id"] == count.group(1))
            return 200, {"results": [[n]], "columns": ["count()"], "types": ["UInt64"], "is_cached": False,
                         "hogql": text}
        persons = PERSONS_RE.match(text)
        if persons:
            rows = [e for e in self.events if e["distinct_id"] == persons.group(1)]
            return 200, {"results": [[len(rows), sorted({e["person_id"] for e in rows})]],
                         "columns": ["count()", "groupUniqArray(toString(person_id))"],
                         "types": ["UInt64", "Array(String)"], "is_cached": False, "hogql": text}
        return 400, {"detail": "unsupported query in the fake"}

    def summary(self):
        with self.lock:
            self.tick()
            return {
                "events": [{"distinct_id": e["distinct_id"], "person_id": e["person_id"],
                            "written_at": iso(e["written_at"]), "event": e["event"]} for e in self.events],
                "accepted_not_written": len(self.accepted),
                "persons": [{"distinct_id": d, "uuid": p["uuid"], "queued": p["queued_at"] is not None}
                            for d, p in self.persons.items()],
                "deletions": [{"person_uuid": u, "created_at": iso(d["created_at"]),
                               "verified_at": iso(d["verified_at"]) if d["verified_at"] else None}
                              for u, d in self.deletions.items()],
            }


def load_secret(path, field):
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    if value.get("synthetic") is not True:
        raise SystemExit(f"refusing: {path} is not marked synthetic")
    return value[field]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--erasure-key-file", required=True)
    parser.add_argument("--capture-config", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--request-log", required=True)
    parser.add_argument("--state-out", required=True)
    parser.add_argument("--ingest-lag", type=float, default=1.0)
    parser.add_argument("--person-removal-delay", type=float, default=1.5)
    parser.add_argument("--deletion-delay", type=float, default=3.0)
    parser.add_argument("--no-query-scope", action="store_true")
    args = parser.parse_args()
    fake = FakePostHog(load_secret(args.erasure_key_file, "apiKey"),
                       load_secret(args.capture_config, "publicWriteToken"),
                       args.ingest_lag, args.person_removal_delay, args.deletion_delay,
                       query_scope=not args.no_query_scope)
    log_lock = threading.Lock()
    log = open(args.request_log, "a", encoding="utf-8")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _serve(self, method):
            length = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(length) if length else b""
            headers = {k.lower(): v for k, v in self.headers.items()}
            status, payload = fake.handle(method, self.path, headers, body)
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            with log_lock:
                log.write(json.dumps({"t": iso(time.time()), "method": method, "path": self.path,
                                      "status": status}) + "\n")
                log.flush()

        def do_GET(self):
            self._serve("GET")

        def do_POST(self):
            self._serve("POST")

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)

    def stop(*_):
        with open(args.state_out, "w", encoding="utf-8") as handle:
            json.dump(fake.summary(), handle, indent=2, sort_keys=True)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with open(args.ready_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    server.serve_forever()
    log.close()


if __name__ == "__main__":
    sys.exit(main())
