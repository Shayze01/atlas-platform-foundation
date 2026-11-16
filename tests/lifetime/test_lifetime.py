#!/usr/bin/env python3
"""Offline tests for scripts/ci/lifetime.py: plan expiry, pre-apply and pre-window gates,
02:00 UK auto-shutdown (GMT/BST conversion) and the 03:30 UTC nightly Destroy."""
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import lifetime as lt  # noqa: E402


def run(*argv):
    lines = []
    rc, outputs = lt.run(list(argv), out=lines.append)
    return rc, outputs, "\n".join(lines)


def plan(now, scenario="healthy", minutes="30"):
    return run("plan", "--scenario", scenario, "--inspection-minutes", minutes, "--now", now)


def gate(phase, now, expires, scenario="healthy", minutes="30"):
    return run(phase, "--scenario", scenario, "--inspection-minutes", minutes, "--expires-at", expires, "--now", now)


class Plan(unittest.TestCase):
    def test_healthy_30_min_window(self):
        rc, out, text = plan("2026-11-16T21:00:00Z")
        self.assertEqual((rc, out["expires_at"], out["budget_minutes"]), (0, "2026-11-16T23:20:00Z", "140"))
        self.assertIn("approval 45 + provision 20 + tests 15 + inspection 30 + cleanup 20 + margin 10 = 140 min", text)

    def test_failure_scenario_never_gets_a_window(self):
        rc, out, text = plan("2026-11-16T21:00:00Z", "deliberate-failure-ignore-status", "45")
        self.assertEqual((rc, out["budget_minutes"], out["inspection_minutes"]), (0, "110", "0"))
        self.assertIn("inspection window disabled", text)

    def test_maximum_window_fits_the_cap(self):
        rc, out, _ = plan("2026-11-16T18:00:00Z", minutes="45")
        self.assertEqual((rc, out["budget_minutes"]), (0, "155"))
        self.assertLessEqual(int(out["budget_minutes"]), lt.CAP_MINUTES)

    def test_expiry_rounded_up_to_the_minute(self):
        self.assertEqual(plan("2026-11-16T21:00:01Z")[1]["expires_at"], "2026-11-16T23:21:00Z")

    def test_winter_auto_shutdown_is_0200_utc(self):
        rc, out, text = plan("2026-11-16T23:00:00Z", minutes="0")  # 110 min -> 00:50Z
        self.assertEqual(rc, 0)
        rc, out, text = plan("2026-11-17T00:15:00Z", minutes="0")  # -> 02:05Z
        self.assertEqual(rc, 1)
        self.assertIn("02:00 UK auto-shutdown (02:00 UTC on 2026-11-17, UK on GMT)", text)
        self.assertNotIn("expires_at", out)

    def test_summer_auto_shutdown_is_0100_utc(self):
        self.assertEqual(plan("2026-07-01T23:00:00Z", minutes="0")[0], 0)        # -> 00:50Z, before 01:00Z
        rc, _, text = plan("2026-07-01T23:00:00Z", minutes="15")                  # -> 01:05Z
        self.assertEqual(rc, 1)
        self.assertIn("02:00 UK auto-shutdown (01:00 UTC on 2026-07-02, UK on BST)", text)
        self.assertEqual(plan("2026-11-16T23:00:00Z", minutes="15")[0], 0)      # same clock time in winter passes

    def test_spring_forward_night(self):
        rc, _, text = plan("2026-03-28T23:30:00Z", "deliberate-failure-ignore-status", "0")  # -> 01:20Z
        self.assertEqual(rc, 1)
        self.assertIn("(01:00 UTC on 2026-03-29, UK on BST)", text)

    def test_autumn_back_night(self):
        rc, _, text = plan("2026-10-24T23:30:00Z", "deliberate-failure-ignore-status", "0")  # -> 01:20Z, shutdown 02:00Z
        self.assertEqual(rc, 0, text)

    def test_nightly_destroy_guard_0320_utc(self):
        rc, _, text = plan("2026-11-17T02:05:00Z", minutes="0")  # after shutdown; -> 03:55Z
        self.assertEqual(rc, 1)
        self.assertIn("nightly Destroy at 03:30 UTC on 2026-11-17 (guarded from 03:20 UTC)", text)
        self.assertEqual(plan("2026-11-17T03:35:00Z", minutes="0")[0], 0)

    def test_start_inside_the_0320_0330_band_sees_todays_destroy(self):
        rc, _, text = plan("2026-11-17T03:25:00Z", minutes="0")
        self.assertEqual(rc, 1)
        self.assertIn("nightly Destroy at 03:30 UTC on 2026-11-17", text)
        self.assertIn("next nightly Destroy 2026-11-17T03:30:00Z", text)
        self.assertEqual(gate("pre-window", "2026-11-17T03:25:00Z", "2026-11-17T05:00:00Z", minutes="15")[0], 1)

    def test_reports_next_safety_net_times(self):
        text = plan("2026-07-01T12:00:00Z")[2]
        self.assertIn("next auto-shutdown 2026-07-02T01:00:00Z (02:00 UK, BST)", text)
        self.assertIn("next nightly Destroy 2026-07-02T03:30:00Z", text)


class PreApply(unittest.TestCase):
    EXP = "2026-11-16T23:20:00Z"

    def test_full_margin_is_kept(self):
        rc, out, text = gate("pre-apply", "2026-11-16T21:45:00Z", self.EXP)  # 95 min left, needs 95
        self.assertEqual((rc, out["decision"]), (0, "pass"))
        rc, out, text = gate("pre-apply", "2026-11-16T21:46:00Z", self.EXP)  # 94 left: margin would be eaten
        self.assertEqual((rc, out["decision"]), (1, "refused"))
        self.assertIn("insufficient lifetime: needs 95 min, 94 min left", text)

    def test_late_approval_uses_the_allowance_not_the_window(self):
        self.assertEqual(gate("pre-apply", "2026-11-16T21:40:00Z", self.EXP)[0], 0)

    def test_blackout_rechecked_even_with_a_long_expiry(self):
        rc, _, text = gate("pre-apply", "2026-07-02T00:00:00Z", "2026-07-02T02:30:00Z", minutes="0")
        self.assertEqual(rc, 1)
        self.assertIn("02:00 UK auto-shutdown (01:00 UTC", text)


class PreWindow(unittest.TestCase):
    def test_window_starts_only_if_it_fits_in_full(self):
        rc, out, _ = gate("pre-window", "2026-11-16T22:20:00Z", "2026-11-16T23:20:00Z")  # needs 30+20+10=60
        self.assertEqual((rc, out["decision"]), (0, "pass"))
        rc, out, text = gate("pre-window", "2026-11-16T22:21:00Z", "2026-11-16T23:20:00Z")
        self.assertEqual((rc, out["decision"]), (1, "refused"))
        self.assertIn("NOT started; it is never shortened", text)
        self.assertNotRegex(text, r"(shortened to|reduced to) \d+")

    def test_window_refused_before_auto_shutdown(self):
        rc, _, text = gate("pre-window", "2026-07-02T00:20:00Z", "2026-07-02T02:00:00Z", minutes="45")
        self.assertEqual(rc, 1)
        self.assertIn("never shortened", text)


class BadInput(unittest.TestCase):
    def test_rejected(self):
        for argv in [("plan", "--scenario", "broken", "--inspection-minutes", "30"),
                     ("plan", "--scenario", "healthy", "--inspection-minutes", "20"),
                     ("plan", "--scenario", "healthy", "--inspection-minutes", "-5"),
                     ("pre-apply", "--scenario", "healthy", "--inspection-minutes", "30"),
                     ("pre-apply", "--scenario", "healthy", "--inspection-minutes", "30", "--expires-at", "2026-11-16 23:20")]:
            with self.subTest(argv=argv):
                self.assertEqual(run(*argv)[0], 2)


class Cli(unittest.TestCase):
    def test_writes_github_output(self):
        with tempfile.NamedTemporaryFile("r") as f:
            r = subprocess.run([sys.executable, ROOT / "scripts/ci/lifetime.py", "plan", "--scenario", "healthy",
                                "--inspection-minutes", "30", "--now", "2026-11-16T21:00:00Z"],
                               env={"GITHUB_OUTPUT": f.name, "PATH": "/usr/bin:/bin"}, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertIn("expires_at=2026-11-16T23:20:00Z\n", f.read())


class MatchesTheConfiguration(unittest.TestCase):
    def test_auto_shutdown_and_destroy_times(self):
        variables = (ROOT / "variables.tf").read_text()
        self.assertRegex(variables, r'variable "auto_shutdown_time" \{[^}]*default\s+= "0200"')
        self.assertRegex(variables, r'variable "auto_shutdown_timezone" \{[^}]*default\s+= "GMT Standard Time"')
        self.assertEqual((lt.AUTO_SHUTDOWN_LOCAL.hour, lt.AUTO_SHUTDOWN_LOCAL.minute), (2, 0))
        cron = re.findall(r'cron: "([^"]+)"', (ROOT / ".github/workflows/destroy.yml").read_text())
        self.assertIn(f"{lt.NIGHTLY_DESTROY_UTC.minute} {lt.NIGHTLY_DESTROY_UTC.hour} * * *", cron)


if __name__ == "__main__":
    unittest.main(verbosity=2)
