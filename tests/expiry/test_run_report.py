#!/usr/bin/env python3
"""Offline tests for scripts/ci/run-report.py: application and cleanup are separate rows,
"application failed, cleanup passed" is a FAILED run, and nothing private is printed."""
import os
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
IMG = "ghcr.io/shayze01/atlas-tickets@sha256:" + "a1" * 32
HEALTHY = dict(SCENARIO="healthy", INSPECTION_MINUTES="30", APP_IMAGE=IMG, EXPIRES_AT="2026-11-16T23:20:00Z",
               PLAN_RESULT="success", APPLY_RESULT="success", APPLY_ATTEMPTED="true", STOPPED_BEFORE_APPLY="",
               FLOW_OUTCOME="success", UI_OUTCOME="success", WINDOW="pass", WINDOW_OUTCOME="success",
               DESTROY_OUTCOME="success", CLEANUP_JOB_RESULT="skipped")


def report(**over):
    env = {k: v for k, v in dict(HEALTHY, **over).items() if v is not None}
    r = subprocess.run([sys.executable, ROOT / "scripts/ci/run-report.py"], env=dict(env, PATH=os.environ["PATH"]),
                       capture_output=True, text=True)
    return r.returncode, r.stdout


class Report(unittest.TestCase):
    def test_healthy_run_passes(self):
        rc, out = report()
        self.assertEqual(rc, 0)
        self.assertIn("| Application tests | PASS |", out)
        self.assertIn("| Inspection window | DONE | 30 min in full |", out)
        self.assertIn("| Cleanup | PASS | in-job destroy", out)
        self.assertIn("**PASSED**", out)

    def test_application_failed_cleanup_passed_is_failed(self):
        rc, out = report(UI_OUTCOME="failure", WINDOW="", WINDOW_OUTCOME="", DESTROY_OUTCOME="skipped",
                         APPLY_RESULT="failure", CLEANUP_JOB_RESULT="success", CLEANUP_DECISION="DESTROY", CLEANUP_RESULT="DESTROYED")
        self.assertEqual(rc, 1)
        self.assertIn("| Application tests | FAIL | API flow: success; browser: failure |", out)
        self.assertIn("| Cleanup | PASS | via failure-cleanup: destroyed and verified |", out)
        self.assertIn("**FAILED**", out)

    def test_failed_deployment_check_with_passing_tests_is_failed(self):
        rc, out = report(INSPECTION_MINUTES="0", WINDOW="", WINDOW_OUTCOME="", DESTROY_OUTCOME="skipped",
                         APPLY_RESULT="failure", CLEANUP_JOB_RESULT="success", CLEANUP_DECISION="DESTROY", CLEANUP_RESULT="DESTROYED")
        self.assertEqual(rc, 1)
        self.assertIn("| Application tests | PASS |", out)
        self.assertIn("| Deployment job | FAIL | apply job failure", out)
        self.assertIn("**FAILED**", out)

    def test_deliberate_failure_scenario(self):
        rc, out = report(SCENARIO="deliberate-failure-ignore-status", INSPECTION_MINUTES="0", FLOW_OUTCOME="failure",
                         UI_OUTCOME="failure", WINDOW="", DESTROY_OUTCOME="skipped", APPLY_RESULT="failure",
                         CLEANUP_JOB_RESULT="success", CLEANUP_DECISION="DESTROY", CLEANUP_RESULT="DESTROYED")
        self.assertEqual(rc, 1)
        self.assertIn("expected for scenario deliberate-failure-ignore-status", out)
        self.assertIn("| Inspection window | n/a | disabled for the deliberate-failure scenario |", out)
        self.assertIn("| Cleanup | PASS | via failure-cleanup", out)

    def test_even_all_passing_fault_build_run_is_failed(self):
        self.assertEqual(report(SCENARIO="deliberate-failure-ignore-status")[0], 1)

    def test_window_refused_fails_the_run(self):
        rc, out = report(WINDOW="refused", WINDOW_OUTCOME="skipped")
        self.assertEqual(rc, 1)
        self.assertIn("| Inspection window | NOT STARTED | insufficient lifetime before the window; never shortened", out)

    def test_cancelled_window(self):
        rc, out = report(WINDOW_OUTCOME="cancelled", DESTROY_OUTCOME="skipped", APPLY_RESULT="cancelled",
                         CLEANUP_JOB_RESULT="success", CLEANUP_RESULT="DESTROYED")
        self.assertEqual(rc, 1)
        self.assertIn("ENDED EARLY", out)

    def test_stopped_before_apply(self):
        rc, out = report(STOPPED_BEFORE_APPLY="true", APPLY_ATTEMPTED="", APPLY_RESULT="failure", FLOW_OUTCOME="",
                         UI_OUTCOME="", WINDOW="", DESTROY_OUTCOME="", CLEANUP_JOB_RESULT="success",
                         CLEANUP_DECISION="NOOP", CLEANUP_RESULT="NOOP")
        self.assertEqual(rc, 1)
        self.assertIn("stopped before apply: insufficient lifetime", out)
        self.assertIn("| Cleanup | PASS | via failure-cleanup: nothing to destroy |", out)

    def test_rejected_plan_with_preexisting_environment(self):
        rc, out = report(APPLY_ATTEMPTED="", APPLY_RESULT="failure", FLOW_OUTCOME="", UI_OUTCOME="", WINDOW="",
                         DESTROY_OUTCOME="", CLEANUP_JOB_RESULT="success", CLEANUP_DECISION="PROTECT", CLEANUP_RESULT="PROTECT")
        self.assertEqual(rc, 1)
        self.assertIn("apply not attempted", out)
        self.assertIn("pre-existing unexpired environment left in place", out)

    def test_cleanup_inconclusive_fails(self):
        rc, out = report(DESTROY_OUTCOME="skipped", APPLY_RESULT="failure", CLEANUP_JOB_RESULT="failure",
                         CLEANUP_DECISION="INCONCLUSIVE", CLEANUP_RESULT="INCONCLUSIVE", FLOW_OUTCOME="failure")
        self.assertEqual(rc, 1)
        self.assertIn("| Cleanup | FAIL |", out)

    def test_plan_failed_nothing_created(self):
        rc, out = report(PLAN_RESULT="failure", APPLY_RESULT="skipped", APPLY_ATTEMPTED="", DESTROY_OUTCOME="",
                         WINDOW="", CLEANUP_JOB_RESULT="skipped")
        self.assertEqual(rc, 1)
        self.assertIn("| Cleanup | PASS | nothing to clean: apply never ran |", out)

    def test_no_url_or_ip(self):
        out = report()[1]
        self.assertNotRegex(out, r"https?://(?!github)|\b\d{1,3}(\.\d{1,3}){3}\b")
        self.assertIn("URL: delivered privately", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
