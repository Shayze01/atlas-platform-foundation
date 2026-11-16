#!/usr/bin/env python3
"""Offline tests for the hourly expiry sweep and the guarded failure-cleanup
(scripts/ci/guarded-destroy.sh + expiry_decision.py), with stub terraform/az/verify.

Covers every row of revision 2 section 6.3 (empty, unexpired, expired, missing,
malformed, conflicting, beyond the cap, state/Azure mismatch, read error, state lock),
and requirement 4: a run that stopped before apply (or whose plan was rejected) never
destroys a pre-existing unexpired environment. Also asserts that `terraform destroy`
runs only on DESTROY and that no az call touches the state backend, identities or
the resource group itself.
"""
import copy
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / "tests" / "expiry" / "fixtures"
STATE = json.loads((FIX / "state-full-deployment.json").read_text())
AZURE = json.loads((FIX / "azure-full-deployment.json").read_text())
EXP = "2026-11-16T22:35:00Z"
EMPTY_STATE = {"format_version": "1.0"}

TERRAFORM = """#!/usr/bin/env bash
echo "terraform $*" >>"$STUB_LOG"
case "$1" in
  show) [[ "${TF_SHOW:-ok}" == fail ]] && { echo "Error: Failed to load state: 403 AuthorizationPermissionMismatch" >&2; exit 1; }
        cat "$STATE_FILE" ;;
  destroy)
    case "${TF_DESTROY:-ok}" in
      lock) echo "Error: Error acquiring the state lock" >&2; exit 1 ;;
      fail) echo "Error: deleting Network Interface: Conflict" >&2; exit 1 ;;
    esac
    echo "Destroy complete! Resources: 12 destroyed." ;;
  *) echo "stub terraform: unexpected $*" >&2; exit 99 ;;
esac
"""
AZ = """#!/usr/bin/env bash
echo "az $*" >>"$STUB_LOG"
case "$*" in
  "resource list --resource-group rg-atlas-foundation-dev --output json")
    [[ "${AZ_LIST:-ok}" == fail ]] && { echo "ERROR: (AuthorizationFailed) no read access" >&2; exit 1; }
    cat "$AZURE_FILE" ;;
  *) echo "stub az: unexpected $*" >&2; exit 99 ;;
esac
"""
VERIFY = """#!/usr/bin/env bash
echo "verify KEEP_RESOURCE_GROUP=${KEEP_RESOURCE_GROUP}" >>"$STUB_LOG"
exit "${VERIFY_RC:-0}"
"""


class GuardedDestroy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)
        for name, body in [("terraform", TERRAFORM), ("az", AZ), ("verify", VERIFY)]:
            p = self.dir / name
            p.write_text(body)
            p.chmod(0o755)
        self.state, self.azure = copy.deepcopy(STATE), copy.deepcopy(AZURE)

    def tearDown(self):
        self.tmp.cleanup()

    def run_mode(self, mode, now, **env):
        (self.dir / "state.json").write_text(json.dumps(self.state))
        (self.dir / "azure.json").write_text(json.dumps(self.azure))
        log, out = self.dir / "calls.log", self.dir / "gh_output"
        for f in (log, out):
            f.write_text("")
        full = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}", STUB_LOG=str(log), MODE=mode,
                    STATE_FILE=str(self.dir / "state.json"), AZURE_FILE=str(self.dir / "azure.json"),
                    VERIFY_CLEANUP=str(self.dir / "verify"), ATLAS_NOW=now, GITHUB_OUTPUT=str(out), **env)
        r = subprocess.run([str(ROOT / "scripts/ci/guarded-destroy.sh")], env=full, capture_output=True, text=True)
        calls = log.read_text()
        self.assertNotIn("rg-atlas-tfstate", calls)
        for forbidden in ("group delete", "az tag", "identity", "role assignment", "storage"):
            self.assertNotIn(forbidden, calls)
        outputs = dict(line.split("=", 1) for line in out.read_text().splitlines())
        return r.returncode, r.stdout + r.stderr, calls, outputs

    def destroyed(self, calls):
        return "terraform destroy" in calls

    def set_tag(self, value, suffix=None):
        for r in self.azure:
            if suffix is None or r["id"].lower().endswith(suffix):
                if isinstance(r.get("tags"), dict):
                    r["tags"]["ExpiresAt"] = value

    def set_state_tag(self, value):
        def walk(m):
            for r in m.get("resources", []):
                yield r
            for c in m.get("child_modules", []):
                yield from walk(c)
        for r in walk(self.state["values"]["root_module"]):
            if "tags" in r.get("values", {}):
                r["values"]["tags"]["ExpiresAt"] = value

    # ---------------- sweep: revision 2 section 6.3 rows
    def test_sweep_empty_is_noop(self):
        self.state, self.azure = EMPTY_STATE, []
        rc, text, calls, out = self.run_mode("sweep", "2026-11-16T23:00:00Z")
        self.assertEqual((rc, out["decision"], self.destroyed(calls)), (0, "NOOP", False))

    def test_sweep_protects_unexpired(self):
        rc, text, calls, out = self.run_mode("sweep", "2026-11-16T22:00:00Z")
        self.assertEqual((rc, out["decision"], self.destroyed(calls)), (0, "PROTECT", False))
        self.assertIn("35 min left", text)

    def test_sweep_protects_within_grace(self):
        rc, _, calls, out = self.run_mode("sweep", "2026-11-16T22:49:59Z")
        self.assertEqual((out["decision"], self.destroyed(calls)), ("PROTECT", False))

    def test_sweep_destroys_expired_and_verifies(self):
        rc, text, calls, out = self.run_mode("sweep", "2026-11-16T22:50:00Z")
        self.assertEqual((rc, out["decision"], out["result"]), (0, "DESTROY", "DESTROYED"))
        self.assertIn("terraform destroy -auto-approve -input=false -lock-timeout=5m -no-color", calls)
        self.assertIn("verify KEEP_RESOURCE_GROUP=1", calls)

    def test_sweep_destroy_verification_failure_fails(self):
        rc, _, _, out = self.run_mode("sweep", "2026-11-17T00:00:00Z", VERIFY_RC="1")
        self.assertEqual((rc, out["result"]), (1, "VERIFY-FAILED"))

    def assert_inconclusive(self, now="2026-11-17T00:00:00Z", **env):
        rc, text, calls, out = self.run_mode("sweep", now, **env)
        self.assertEqual((rc, out.get("decision"), self.destroyed(calls)), (2, "INCONCLUSIVE", False), text)
        return text

    def test_sweep_missing_tag(self):
        del self.azure[2]["tags"]["ExpiresAt"]
        self.assertIn("missing ExpiresAt", self.assert_inconclusive())

    def test_sweep_malformed_tag(self):
        self.set_tag("2026-11-16 22:35", "/vm-atlas-foundation-dev")
        self.assertIn("malformed ExpiresAt", self.assert_inconclusive())

    def test_sweep_conflicting_tags(self):
        self.set_tag("2026-11-16T20:00:00Z", "/nsg-atlas-foundation-dev")
        self.state["values"]["root_module"]["child_modules"][0]["resources"][2]["values"]["tags"] = dict(
            self.state["values"]["root_module"]["child_modules"][0]["resources"][2]["values"]["tags"], ExpiresAt="2026-11-16T20:00:00Z")
        self.assertIn("conflicting ExpiresAt", self.assert_inconclusive())

    def test_sweep_beyond_the_cap(self):
        self.set_tag("2026-11-17T09:00:00Z")
        self.set_state_tag("2026-11-17T09:00:00Z")
        self.assertIn("more than 3 h ahead", self.assert_inconclusive("2026-11-17T00:00:00Z"))

    def test_sweep_state_and_azure_disagree(self):
        self.azure = self.azure[:-1]
        self.assertIn("in state but not in Azure", self.assert_inconclusive())

    def test_sweep_unmanaged_resource_in_group(self):
        extra = copy.deepcopy(self.azure[0]); extra["id"] += "-manual"
        self.azure.append(extra)
        self.assertIn("in Azure but not explained by state", self.assert_inconclusive())

    def test_sweep_state_read_error(self):
        self.assertIn("cannot read Terraform state", self.assert_inconclusive(TF_SHOW="fail"))

    def test_sweep_azure_read_error(self):
        self.assertIn("cannot list resources", self.assert_inconclusive(AZ_LIST="fail"))

    def test_sweep_state_lock(self):
        rc, text, calls, out = self.run_mode("sweep", "2026-11-17T00:00:00Z", TF_DESTROY="lock")
        self.assertEqual((rc, out["result"]), (2, "INCONCLUSIVE"))
        self.assertNotIn("verify", calls)

    def test_sweep_unreadable_state_json(self):
        self.state = "not json {"
        (self.dir / "state.json").write_text("not json {")
        self.assert_inconclusive()

    # ---------------- failure-cleanup: requirement 4
    def test_rejected_plan_never_destroys_a_preexisting_unexpired_environment(self):
        """Plan rejected / not approved / hash mismatch / stopped before apply: APPLY_ATTEMPTED is
        not true. A pre-existing environment (ExpiresAt 22:35Z, not this run's 23:20Z) is kept."""
        for attempted in ("false", ""):
            with self.subTest(apply_attempted=attempted or "<unknown>"):
                rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z",
                                                     APPLY_ATTEMPTED=attempted, OWN_EXPIRES_AT="2026-11-16T23:20:00Z")
                self.assertEqual((rc, out["decision"], self.destroyed(calls)), (0, "PROTECT", False), text)
                self.assertIn("pre-existing environment is unexpired", text)

    def test_stopped_before_apply_with_empty_group_is_noop(self):
        self.state, self.azure = EMPTY_STATE, []
        rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z", APPLY_ATTEMPTED="false",
                                             OWN_EXPIRES_AT="2026-11-16T23:20:00Z")
        self.assertEqual((rc, out["decision"], self.destroyed(calls)), (0, "NOOP", False))
        self.assertIn("this run created nothing", text)

    def test_apply_attempted_destroys_without_reading_tags(self):
        self.set_tag("garbage")  # even uncertain tags: this run touched the workload
        rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z", APPLY_ATTEMPTED="true",
                                             OWN_EXPIRES_AT="2026-11-16T23:20:00Z")
        self.assertEqual((rc, out["result"]), (0, "DESTROYED"))
        self.assertNotIn("az resource list", calls)

    def test_unknown_attempt_but_resources_carry_this_runs_expiry(self):
        rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z", APPLY_ATTEMPTED="",
                                             OWN_EXPIRES_AT=EXP)
        self.assertEqual((out["decision"], self.destroyed(calls)), ("DESTROY", True))

    def test_not_attempted_and_uncertain_tags_is_inconclusive(self):
        del self.azure[0]["tags"]["ExpiresAt"]
        rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z", APPLY_ATTEMPTED="false",
                                             OWN_EXPIRES_AT="2026-11-16T23:20:00Z")
        self.assertEqual((rc, out["decision"], self.destroyed(calls)), (2, "INCONCLUSIVE", False))

    def test_bad_apply_attempted_value(self):
        rc, *_ = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z", APPLY_ATTEMPTED="yes")
        self.assertEqual(rc, 2)

    def test_bad_mode(self):
        rc, *_ = self.run_mode("nuke", "2026-11-16T21:00:00Z")
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
