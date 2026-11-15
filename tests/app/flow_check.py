#!/usr/bin/env python3
"""Independent ticket-flow check for the Atlas Service Desk API.

Does not import the app. Uses only the Python standard library, so the same file
runs locally and against a deployed environment.

Flow: create a ticket -> change its status Open -> In progress -> read it back ->
verify the saved status, priority and history.

Exit codes:
  0  the saved result is correct
  3  the app answered, but the saved result is wrong (e.g. status not saved)
  2  environment problem (cannot connect, unexpected HTTP status, bad JSON)

The target URL is never printed, so a deployed address does not reach logs.
Usage: flow_check.py --base-url http://127.0.0.1:8088 [--label TEXT]
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

EXPECTED_STATUS = "In progress"
EXPECTED_PRIORITY = "High"


class EnvironmentProblem(Exception):
    pass


class WrongResult(Exception):
    pass


def call(base, method, path, body=None, expect=200):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            status, raw = res.status, res.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except (urllib.error.URLError, OSError) as e:
        raise EnvironmentProblem(f"{method} {path}: cannot reach target ({type(e).__name__})") from None
    if status != expect:
        raise EnvironmentProblem(f"{method} {path}: expected HTTP {expect}, got {status}")
    try:
        return json.loads(raw)
    except ValueError:
        raise EnvironmentProblem(f"{method} {path}: response is not JSON") from None


def run(base, label):
    created = call(base, "POST", "/api/tickets", {
        "title": f"{label} flow check",
        "description": "Automated flow check with fictional data.",
        "requester": "Flow Check (fictional)",
        "priority": EXPECTED_PRIORITY,
    }, expect=201)
    ticket_id = created.get("id")
    if not isinstance(ticket_id, int):
        raise EnvironmentProblem("POST /api/tickets: response has no numeric id")
    print(f"STEP: created ticket {created.get('reference')} (status {created.get('status')!r})")
    if created.get("status") != "Open":
        raise WrongResult(f"new ticket status: expected 'Open', got {created.get('status')!r}")

    call(base, "PATCH", f"/api/tickets/{ticket_id}", {"status": EXPECTED_STATUS})
    print(f"STEP: requested status change to {EXPECTED_STATUS!r}")

    saved = call(base, "GET", f"/api/tickets/{ticket_id}")
    print(f"STEP: read ticket back (status {saved.get('status')!r})")
    if saved.get("status") != EXPECTED_STATUS:
        raise WrongResult(f"status mismatch: expected {EXPECTED_STATUS!r}, got {saved.get('status')!r}")
    print(f"PASS: saved status is {EXPECTED_STATUS!r}")
    if saved.get("priority") != EXPECTED_PRIORITY:
        raise WrongResult(f"priority mismatch: expected {EXPECTED_PRIORITY!r}, got {saved.get('priority')!r}")
    print(f"PASS: saved priority is {EXPECTED_PRIORITY!r}")
    changes = [(h.get("field"), h.get("old_value"), h.get("new_value")) for h in saved.get("history", [])]
    if ("status", "Open", EXPECTED_STATUS) not in changes:
        raise WrongResult(f"history has no 'status: Open -> {EXPECTED_STATUS}' entry")
    print("PASS: history records the status change")

    listed = call(base, "GET", "/api/tickets?status=In%20progress")
    if ticket_id not in [t.get("id") for t in listed.get("tickets", [])]:
        raise WrongResult("ticket missing from the 'In progress' list filter")
    print("PASS: ticket appears under the 'In progress' filter")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--label", default="CI-TEST")
    args = parser.parse_args()
    try:
        run(args.base_url.rstrip("/"), args.label)
    except WrongResult as e:
        print(f"FAIL: {e}")
        return 3
    except EnvironmentProblem as e:
        print(f"ERROR: {e}")
        return 2
    print("RESULT: ticket flow PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
