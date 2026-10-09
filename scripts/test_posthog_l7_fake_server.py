#!/usr/bin/env python3
"""Checks that the L7 dry-run fake reproduces the documented PostHog semantics."""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from posthog_l7_fake_server import FakePostHog  # noqa: E402

KEY, TOKEN = "synthetic-l7-personal-key-test", "synthetic-l7-project-token-test"
SUBJECT = "7e57da7a-1111-4222-8333-444455556666"
AUTH = {"authorization": f"Bearer {KEY}"}


class Clock:
    def __init__(self):
        self.now = 1_000_000.0

    def __call__(self):
        return self.now


class FakeSemanticsTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.fake = FakePostHog(KEY, TOKEN, ingest_lag=1.0, person_removal_delay=1.5, deletion_delay=3.0,
                                clock=self.clock)

    def advance(self, seconds):
        self.clock.now += seconds

    def call(self, method, path, body=None, headers=AUTH):
        data = json.dumps(body).encode() if body is not None else b""
        return self.fake.handle(method, path, headers, data)

    def capture(self, profile=True):
        return self.call("POST", "/capture/", {"api_key": TOKEN, "event": "e", "uuid": "u",
                                               "properties": {"distinct_id": SUBJECT,
                                                              "$process_person_profile": profile}}, headers={})

    def count(self):
        status, body = self.call("POST", "/api/projects/298161/query/", {
            "query": {"kind": "HogQLQuery", "query": f"SELECT count() FROM events WHERE distinct_id = '{SUBJECT}'"},
            "refresh": "force_blocking"})
        self.assertEqual(status, 200)
        self.assertIs(body["is_cached"], False)
        return body["results"][0][0]

    def persons(self):
        return self.call("GET", f"/api/projects/298161/persons/?distinct_id={SUBJECT}")[1]["results"]

    def delete(self):
        return self.call("POST", "/api/projects/298161/persons/bulk_delete/",
                         {"distinct_ids": [SUBJECT], "delete_events": True, "keep_person": False,
                          "delete_recordings": False})

    def status_rows(self, person):
        return self.call("GET", f"/api/projects/298161/persons/deletion_status/?person_uuid={person}&status=all")[1]["results"]

    def test_capture_is_stored_only_after_the_lag_and_creates_a_derived_profile(self):
        self.assertEqual(self.capture()[0], 200)
        self.assertEqual(self.count(), 0)
        self.assertEqual(self.persons(), [])
        self.advance(1.0)
        self.assertEqual(self.count(), 1)
        people = self.persons()
        self.assertEqual(len(people), 1)
        self.assertEqual(people[0]["uuid"], FakePostHog.derived(SUBJECT))
        self.assertEqual(people[0]["distinct_ids"], [SUBJECT])

    def test_deletion_covers_only_rows_written_before_the_request_and_is_unique_per_uuid(self):
        self.capture()
        self.advance(2)
        status, ack = self.delete()
        self.assertEqual(status, 202)
        self.assertEqual((ack["persons_found"], ack["persons_queued_for_deletion"], ack["events_queued_for_deletion"]),
                         (1, 1, True))
        person = FakePostHog.derived(SUBJECT)
        first = self.status_rows(person)
        self.assertEqual(first[0]["status"], "pending")
        self.advance(0.2)
        self.capture()  # accepted after the request, written before the person is removed
        self.advance(3.0)
        rows = self.status_rows(person)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "completed")
        self.assertIsNotNone(rows[0]["delete_verified_at"])
        self.assertEqual(self.persons(), [], "the queued person was removed")
        self.assertEqual(self.count(), 1, "the late row survives: written after created_at")
        # A re-issued deletion is acknowledged but returns the original row.
        self.capture()
        self.advance(1.0)
        self.assertEqual(self.persons()[0]["uuid"], person, "the late event recreated the same UUID")
        status, ack = self.delete()
        self.assertEqual(status, 202)
        self.assertIs(ack["events_queued_for_deletion"], True)
        again = self.status_rows(person)
        self.assertEqual(len(again), 1)
        self.assertEqual(again[0]["created_at"], rows[0]["created_at"], "same row, same created_at")
        self.advance(10)
        self.assertEqual(self.count(), 2, "nothing written after the first request is ever deleted")

    def test_personless_events_get_the_derived_person_id_without_a_profile(self):
        self.capture(profile=False)
        self.advance(1.0)
        self.assertEqual(self.persons(), [])
        status, ack = self.delete()
        self.assertEqual((status, ack["persons_found"], ack["events_queued_for_deletion"]), (202, 0, False))
        status, body = self.call("POST", "/api/projects/298161/query/", {
            "query": {"kind": "HogQLQuery", "query": "SELECT count(), groupUniqArray(toString(person_id)) FROM events "
                                                      f"WHERE distinct_id = '{SUBJECT}'"},
            "refresh": "force_blocking"})
        self.assertEqual(body["results"], [[1, [FakePostHog.derived(SUBJECT)]]])

    def test_auth_project_scope_and_unknown_paths_are_refused(self):
        self.assertEqual(self.call("GET", "/api/projects/298161/persons/?distinct_id=x", headers={})[0], 401)
        self.assertEqual(self.call("GET", "/api/projects/123/persons/?distinct_id=x")[0], 403)
        self.assertEqual(self.call("GET", "/api/projects/298161/events/")[0], 404)
        self.assertEqual(self.call("POST", "/capture/", {"api_key": "other", "properties": {"distinct_id": SUBJECT}},
                                   headers={})[0], 401)
        scoped = FakePostHog(KEY, TOKEN, query_scope=False, clock=self.clock)
        status, _ = scoped.handle("POST", "/api/projects/298161/query/", AUTH, b"{}")
        self.assertEqual(status, 403)


if __name__ == "__main__":
    unittest.main()
