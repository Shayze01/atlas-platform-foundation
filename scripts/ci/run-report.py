#!/usr/bin/env python3
"""Final Deploy report: application results and cleanup results as SEPARATE rows.

Reads job results/outputs from the environment (set by the `report` job) and prints a
Markdown table for the run summary. Contains no URL, IP or identifier.
Exit 0 only when the healthy scenario passed every application test, the requested
inspection window ran in full (or none was requested) and cleanup passed. "Application
failed, cleanup passed" is always a FAILED run; the deliberate-failure scenario always
ends FAILED by design.
"""
import os
import sys

E = os.environ.get


def app_row():
    if E("STOPPED_BEFORE_APPLY") == "true":
        return "NOT RUN", "stopped before apply: insufficient lifetime (nothing created by this run)"
    if E("APPLY_RESULT") in ("", "skipped"):
        return "NOT RUN", f"apply job {E('APPLY_RESULT') or 'did not run'} (plan result: {E('PLAN_RESULT', '?')})"
    if E("APPLY_ATTEMPTED") != "true":
        return "NOT RUN", f"apply not attempted (apply job {E('APPLY_RESULT')}: plan rejected, not approved, hash mismatch or earlier failure)"
    flow, ui = E("FLOW_OUTCOME") or "not reached", E("UI_OUTCOME") or "not reached"
    status = "PASS" if flow == "success" and ui == "success" else "FAIL"
    detail = f"API flow: {flow}; browser: {ui}"
    if status == "FAIL" and E("SCENARIO") == "deliberate-failure-ignore-status":
        detail += " - expected for scenario deliberate-failure-ignore-status (status updates are ignored)"
    return status, detail


def window_row():
    if E("SCENARIO") == "deliberate-failure-ignore-status":
        return "n/a", "disabled for the deliberate-failure scenario"
    if E("INSPECTION_MINUTES", "0") == "0":
        return "n/a", "not requested"
    w = E("WINDOW")
    if w == "refused":
        return "NOT STARTED", "insufficient lifetime before the window; never shortened (run fails)"
    if w == "pass" and E("WINDOW_OUTCOME") == "success":
        return "DONE", f"{E('INSPECTION_MINUTES')} min in full"
    if w == "pass":
        return "ENDED EARLY", f"window step {E('WINDOW_OUTCOME') or 'not finished'} (e.g. run cancelled)"
    return "NOT REACHED", "earlier step did not succeed"


def cleanup_row():
    if E("DESTROY_OUTCOME") == "success":
        return "PASS", "in-job destroy, verified: workload gone, resource group kept"
    fc, decision, result = E("CLEANUP_JOB_RESULT", ""), E("CLEANUP_DECISION", ""), E("CLEANUP_RESULT", "")
    if fc in ("", "skipped"):
        if E("APPLY_RESULT") in ("", "skipped"):
            return "PASS", "nothing to clean: apply never ran"
        return "FAIL", f"in-job destroy {E('DESTROY_OUTCOME') or 'not run'} and failure-cleanup did not run"
    if fc == "success" and result in ("DESTROYED", "NOOP", "PROTECT"):
        meaning = {"DESTROYED": "destroyed and verified", "NOOP": "nothing to destroy",
                   "PROTECT": "pre-existing unexpired environment left in place (not this run's)"}[result]
        return "PASS", f"via failure-cleanup: {meaning}"
    return "FAIL", f"via failure-cleanup: job {fc}, decision {decision or '?'}, result {result or '?'}"


def main():
    rows = [("Application tests",) + app_row(), ("Inspection window",) + window_row(), ("Cleanup",) + cleanup_row()]
    healthy = E("SCENARIO") == "healthy"
    ok = (healthy and rows[0][1] == "PASS" and rows[1][1] in ("n/a", "DONE") and rows[2][1] == "PASS")
    print("### Atlas deployment report\n")
    print(f"- Scenario: `{E('SCENARIO', '?')}`; image: `{E('APP_IMAGE') or 'not built'}`; ExpiresAt (UTC): `{E('EXPIRES_AT') or 'not planned'}`")
    print("- URL: delivered privately (never written to this public log)\n")
    print("| Row | Result | Detail |\n| --- | --- | --- |")
    for name, status, detail in rows:
        print(f"| {name} | {status} | {detail} |")
    print(f"| Run result | **{'PASSED' if ok else 'FAILED'}** | application and cleanup are reported separately; any application failure fails the run |")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
