"""Unit tests for the Atlas Service Desk API (Flask test client, temporary SQLite file).

Run inside the app image so the exact pinned dependencies are used:
  docker run --rm -v "$PWD/tests/app/unit:/tests:ro" atlas-tickets:local-test \
    python -m unittest discover -s /tests -v
"""
import os
import tempfile
import unittest

from atlas_tickets import create_app, db


class TicketApiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        path = os.path.join(self.tmp.name, "tickets.db")
        db.init(path)
        self.client = create_app(path).test_client()

    def tearDown(self):
        self.tmp.cleanup()

    def create(self, **overrides):
        body = {"title": "Laptop will not boot", "requester": "Sam Example", "priority": "High",
                "description": "Fictional."}
        body.update(overrides)
        return self.client.post("/api/tickets", json=body)

    def test_seed_is_fictional_and_created_once(self):
        tickets = self.client.get("/api/tickets").get_json()["tickets"]
        self.assertEqual(len(tickets), len(db.SEED))
        db.init(self.client.application.config["DB_PATH"])
        self.assertEqual(len(self.client.get("/api/tickets").get_json()["tickets"]), len(db.SEED))
        text = " ".join(f"{t['title']} {t['description']} {t['requester']}" for t in tickets).lower()
        self.assertNotIn("bofa", text)
        self.assertNotIn("bank of america", text)

    def test_create_then_get(self):
        res = self.create()
        self.assertEqual(res.status_code, 201)
        ticket = res.get_json()
        self.assertEqual(res.headers["Location"], f"/api/tickets/{ticket['id']}")
        self.assertEqual((ticket["status"], ticket["priority"]), ("Open", "High"))
        self.assertTrue(ticket["reference"].startswith("ATL-"))
        got = self.client.get(f"/api/tickets/{ticket['id']}").get_json()
        self.assertEqual(got["title"], "Laptop will not boot")
        self.assertEqual(got["history"][0]["field"], "created")

    def test_status_and_priority_update_are_saved_with_history(self):
        tid = self.create().get_json()["id"]
        res = self.client.patch(f"/api/tickets/{tid}", json={"status": "In progress", "priority": "Critical"})
        self.assertEqual(res.status_code, 200)
        saved = self.client.get(f"/api/tickets/{tid}").get_json()
        self.assertEqual((saved["status"], saved["priority"]), ("In progress", "Critical"))
        changes = [(h["field"], h["old_value"], h["new_value"]) for h in saved["history"]]
        self.assertIn(("status", "Open", "In progress"), changes)
        self.assertIn(("priority", "High", "Critical"), changes)

    def test_unchanged_value_adds_no_history(self):
        tid = self.create().get_json()["id"]
        self.client.patch(f"/api/tickets/{tid}", json={"status": "Open"})
        self.assertEqual(len(self.client.get(f"/api/tickets/{tid}").get_json()["history"]), 1)

    def test_filters(self):
        tid = self.create(priority="Critical").get_json()["id"]
        self.client.patch(f"/api/tickets/{tid}", json={"status": "Resolved"})
        ids = [t["id"] for t in self.client.get("/api/tickets?status=Resolved&priority=Critical").get_json()["tickets"]]
        self.assertEqual(ids, [tid])
        self.assertEqual(self.client.get("/api/tickets?status=Nope").status_code, 400)
        self.assertEqual(self.client.get("/api/tickets?priority=Nope").status_code, 400)

    def test_validation(self):
        cases = [({"title": "x"}, "title"), ({"requester": ""}, "requester"), ({"priority": "Urgent"}, "priority"),
                 ({"title": 123}, "title"), ({"description": "d" * 2001}, "description")]
        for overrides, field in cases:
            with self.subTest(field=field):
                res = self.create(**overrides)
                self.assertEqual(res.status_code, 400)
                self.assertIn(field, res.get_json()["fields"])
        tid = self.create().get_json()["id"]
        self.assertEqual(self.client.patch(f"/api/tickets/{tid}", json={"status": "Done"}).status_code, 400)
        self.assertEqual(self.client.patch(f"/api/tickets/{tid}", json={}).status_code, 400)
        self.assertEqual(self.client.patch(f"/api/tickets/{tid}", json=[1]).status_code, 400)

    def test_json_content_type_required(self):
        res = self.client.post("/api/tickets", data="title=x", content_type="application/x-www-form-urlencoded")
        self.assertEqual(res.status_code, 415)

    def test_body_size_limit(self):
        self.assertEqual(self.create(description="d" * 20000).status_code, 413)

    def test_not_found(self):
        self.assertEqual(self.client.get("/api/tickets/9999").status_code, 404)
        self.assertEqual(self.client.patch("/api/tickets/9999", json={"status": "Closed"}).status_code, 404)
        self.assertEqual(self.client.get("/nope").status_code, 404)

    def test_security_headers(self):
        with self.client.get("/") as res:
            self.assertEqual(res.status_code, 200)
            self.assertIn("default-src 'self'", res.headers["Content-Security-Policy"])
            self.assertEqual(res.headers["X-Frame-Options"], "DENY")
            self.assertEqual(res.headers["X-Content-Type-Options"], "nosniff")

    def test_health_and_version(self):
        self.assertEqual(self.client.get("/health").get_json(), {"status": "ok"})
        version = self.client.get("/version").get_json()
        self.assertEqual(set(version), {"app", "variant", "revision", "build_time"})


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        path = os.path.join(self.tmp.name, "tickets.db")
        db.init(path)
        self.client = create_app(path).test_client()
        self.saved = os.environ.get("ATLAS_EXPIRES_AT")

    def tearDown(self):
        if self.saved is None:
            os.environ.pop("ATLAS_EXPIRES_AT", None)
        else:
            os.environ["ATLAS_EXPIRES_AT"] = self.saved
        self.tmp.cleanup()

    def test_expiry_shown_only_when_well_formed(self):
        for value, expected in [("2026-11-15T18:00:00Z", "2026-11-15T18:00:00Z"), ("2026-11-15 18:00", None),
                                ("tomorrow", None), ("", None)]:
            with self.subTest(value=value):
                os.environ["ATLAS_EXPIRES_AT"] = value
                env = self.client.get("/api/environment").get_json()
                self.assertEqual(env["expires_at"], expected)
                self.assertTrue(env["fictional_data"])


if __name__ == "__main__":
    unittest.main()
