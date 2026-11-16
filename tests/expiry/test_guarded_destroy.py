#!/usr/bin/env python3
"""Offline tests for the hourly expiry sweep and the guarded failure-cleanup
(scripts/ci/guarded-destroy.sh + expiry_decision.py), with stub terraform/az/verify.

Covers every row of revision 2 section 6.3 (empty, unexpired, expired, missing,
malformed, conflicting, beyond the cap, state/Azure mismatch, read error, state lock),
and requirement 4: a run that stopped before apply (or whose plan was rejected) never
destroys a pre-existing unexpired environment. After an apply attempt, ownership comes
from the pre-apply/current state snapshots: stale plan, lock rejection, partial apply,
state-read and persistence failures, and a pre-existing unexpired environment. Also asserts that `terraform destroy`
runs only on DESTROY and that no az call touches the state backend, identities or
the resource group itself.
"""
import copy
import json
import re
import os
import pathlib
import subprocess
import sys
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
  state) [[ "$2" == pull ]] || exit 99
         [[ "${TF_PULL:-ok}" == fail ]] && { echo "Error: Failed to load state: 403 AuthorizationPermissionMismatch" >&2; exit 1; }
         cat "$RAW_FILE" ;;
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


ADDR = re.compile(r"^(?:(module\.[^.]+)\.)?([^.]+)\.([^\[]+)(?:\[(\d+)\])?$")


def raw_state(show_state, serial, lineage="3f1c-lineage-a"):
    """Raw `terraform state pull` JSON for a `terraform show -json` style state."""
    def walk(m):
        for r in m.get("resources", []):
            yield r
        for c in m.get("child_modules", []):
            yield from walk(c)
    resources = []
    show_state = show_state if isinstance(show_state, dict) else {}
    for r in walk((show_state.get("values") or {}).get("root_module") or {}):
        if r.get("mode", "managed") == "data":
            continue
        module, rtype, name, idx = ADDR.match(r["address"]).groups()
        inst = {"attributes": r.get("values", {})}
        if idx is not None:
            inst["index_key"] = int(idx)
        res = {"mode": "managed", "type": rtype, "name": name, "instances": [inst]}
        if module:
            res["module"] = module
        resources.append(res)
    return {"version": 4, "serial": serial, "lineage": lineage, "resources": resources}


def snapshot_of(raw):
    r = subprocess.run([sys.executable, str(ROOT / "scripts/ci/state_snapshot.py"), "/dev/stdin"],
                       input=json.dumps(raw) if raw is not None else "", capture_output=True, text=True, check=True)
    return r.stdout.strip()


class GuardedDestroy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)
        for name, body in [("terraform", TERRAFORM), ("az", AZ), ("verify", VERIFY)]:
            p = self.dir / name
            p.write_text(body)
            p.chmod(0o755)
        self.state, self.azure = copy.deepcopy(STATE), copy.deepcopy(AZURE)
        self.raw = None

    def tearDown(self):
        self.tmp.cleanup()

    def run_mode(self, mode, now, **env):
        (self.dir / "state.json").write_text(json.dumps(self.state))
        (self.dir / "azure.json").write_text(json.dumps(self.azure))
        raw = self.raw if self.raw is not None else raw_state(self.state, 7)
        (self.dir / "raw.tfstate").write_text(raw if isinstance(raw, str) else json.dumps(raw))
        log, out = self.dir / "calls.log", self.dir / "gh_output"
        for f in (log, out):
            f.write_text("")
        full = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}", STUB_LOG=str(log), MODE=mode,
                    STATE_FILE=str(self.dir / "state.json"), RAW_FILE=str(self.dir / "raw.tfstate"), AZURE_FILE=str(self.dir / "azure.json"),
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
                self.assertIn("environment is unexpired", text)

    def test_stopped_before_apply_with_empty_group_is_noop(self):
        self.state, self.azure = EMPTY_STATE, []
        rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z", APPLY_ATTEMPTED="false",
                                             OWN_EXPIRES_AT="2026-11-16T23:20:00Z")
        self.assertEqual((rc, out["decision"], self.destroyed(calls)), (0, "NOOP", False))
        self.assertIn("this run created nothing", text)

    # ---------------- failure-cleanup after an apply attempt: ownership from state snapshots
    OWN = "2026-11-16T23:20:00Z"  # this run's ExpiresAt; the fixture environment carries EXP (22:35Z)

    def attempted(self, now="2026-11-16T21:00:00Z", pre=None, own=None, error="", **env):
        pre = snapshot_of(raw_state(STATE, 7)) if pre is None else pre
        return self.run_mode("failure-cleanup", now, APPLY_ATTEMPTED="true", OWN_EXPIRES_AT=own or self.OWN,
                             PRE_APPLY_SNAPSHOT=pre, APPLY_ERROR=error, **env)

    def assert_attempted(self, expect, rc_expect, *, destroyed, **kw):
        rc, text, calls, out = self.attempted(**kw)
        self.assertEqual((rc, out.get("decision"), self.destroyed(calls)), (rc_expect, expect, destroyed), text)
        return text

    def test_attempt_fresh_deployment_created_by_this_run_is_destroyed(self):
        """Apply succeeded from an empty state and a later check/test failed (e.g. the
        deliberate-failure scenario): every resource is this run's and is destroyed."""
        self.raw = raw_state(self.state, 8)
        text = self.assert_attempted("DESTROY", 0, destroyed=True, own=EXP, pre=snapshot_of(None))
        self.assertIn("created by this run", text)

    def test_attempt_fresh_deployment_from_emptied_state_is_destroyed(self):
        self.raw = raw_state(self.state, 12)
        self.assert_attempted("DESTROY", 0, destroyed=True, own=EXP, pre=snapshot_of(raw_state(EMPTY_STATE, 11)))

    def test_lock_rejection_protects_preexisting_unexpired_environment(self):
        text = self.assert_attempted("PROTECT", 0, destroyed=False, error="state-lock")
        self.assertIn("terraform apply recorded no change (state-lock)", text)

    def test_stale_plan_protects_preexisting_unexpired_environment(self):
        text = self.assert_attempted("PROTECT", 0, destroyed=False, error="stale-plan")
        self.assertIn("recorded no change (stale-plan)", text)

    def test_rejected_apply_with_expired_environment_follows_sweep_rules(self):
        self.assert_attempted("DESTROY", 0, destroyed=True, error="stale-plan", now="2026-11-16T23:00:00Z")

    def test_rejected_apply_into_empty_state_is_noop(self):
        self.state, self.azure = EMPTY_STATE, []
        self.raw = raw_state(EMPTY_STATE, 3)
        self.assert_attempted("NOOP", 0, destroyed=False, error="state-lock", pre=snapshot_of(raw_state(EMPTY_STATE, 3)))

    def test_unchanged_serial_does_not_prove_azure_untouched(self):
        """Same serial, but Azure holds an unrecorded resource or an updated tag: protected."""
        extra = copy.deepcopy(self.azure[2]); extra["id"] += "-2"
        self.azure.append(extra)
        self.assertIn("in Azure but not explained by state", self.assert_attempted("INCONCLUSIVE", 2, destroyed=False))
        self.azure = copy.deepcopy(AZURE)
        self.set_tag(self.OWN, "/vm-atlas-foundation-dev")
        self.assertIn("differs between Azure", self.assert_attempted("INCONCLUSIVE", 2, destroyed=False))

    def test_unchanged_serial_but_different_state_is_inconclusive(self):
        pre = json.loads(snapshot_of(raw_state(STATE, 7))); pre["addresses"] = pre["addresses"][:-1]
        self.assert_attempted("INCONCLUSIVE", 2, destroyed=False, pre=json.dumps(pre))

    def test_partial_apply_over_preexisting_unexpired_environment_is_inconclusive(self):
        """Apply updated some carriers to this run's ExpiresAt, then failed: mixed tags."""
        self.set_tag(self.OWN, "/nsg-atlas-foundation-dev")
        self.state["values"]["root_module"]["child_modules"][0]["resources"][2]["values"]["tags"]["ExpiresAt"] = self.OWN
        self.raw = raw_state(self.state, 8)
        self.assert_attempted("INCONCLUSIVE", 2, destroyed=False)

    def test_changed_serial_alone_never_authorises_destroying_a_preexisting_environment(self):
        """Every carrier now has this run's ExpiresAt, but the resources existed before apply."""
        self.set_tag(self.OWN); self.set_state_tag(self.OWN)
        self.raw = raw_state(self.state, 8)
        text = self.assert_attempted("INCONCLUSIVE", 2, destroyed=False)
        self.assertIn("a changed serial does not make it this run's", text)

    def test_changed_preexisting_environment_that_had_expired_is_destroyed(self):
        self.set_tag(self.OWN); self.set_state_tag(self.OWN)
        self.raw = raw_state(self.state, 8)
        self.assert_attempted("DESTROY", 0, destroyed=True, now="2026-11-16T22:55:00Z")

    def test_partial_apply_from_empty_state_destroys_only_what_it_created(self):
        nets = self.state["values"]["root_module"]["child_modules"][0]
        self.state["values"]["root_module"]["child_modules"] = [nets]
        keep = ("/vnet-atlas-foundation-dev", "/nsg-atlas-foundation-dev")
        self.azure = [r for r in self.azure if r["id"].lower().endswith(keep)]
        self.raw = raw_state(self.state, 2)
        text = self.assert_attempted("DESTROY", 0, destroyed=True, own=EXP, pre=snapshot_of(None))
        self.assertIn("created by this run", text)

    def test_partial_apply_from_empty_state_with_foreign_expiry_is_inconclusive(self):
        self.raw = raw_state(self.state, 2)
        self.assert_attempted("INCONCLUSIVE", 2, destroyed=False, pre=snapshot_of(None))

    def test_state_persistence_failure_is_inconclusive(self):
        text = self.assert_attempted("INCONCLUSIVE", 2, destroyed=False, error="state-persist-failed", own=EXP,
                                     pre=snapshot_of(None))
        self.assertIn("could not persist state", text)
        self.assertIn("manual recovery required", text)

    def test_state_read_failures_after_attempt_are_inconclusive(self):
        for env in ({"TF_SHOW": "fail"}, {"TF_PULL": "fail"}, {"AZ_LIST": "fail"}):
            with self.subTest(**env):
                self.assert_attempted("INCONCLUSIVE", 2, destroyed=False, **env)
        self.raw = "not json {"
        self.assert_attempted("INCONCLUSIVE", 2, destroyed=False)

    def test_missing_or_bad_pre_apply_snapshot_is_inconclusive(self):
        for pre in ("", "{}", "garbage"):
            with self.subTest(pre=pre):
                text = self.assert_attempted("INCONCLUSIVE", 2, destroyed=False, pre=pre)
                self.assertIn("no valid pre-apply state snapshot", text)

    def test_replaced_state_lineage_or_older_serial_is_inconclusive(self):
        self.raw = raw_state(self.state, 9, lineage="other-lineage")
        self.assertIn("lineage changed", self.assert_attempted("INCONCLUSIVE", 2, destroyed=False))
        self.raw = raw_state(self.state, 6)
        self.assertIn("went backwards", self.assert_attempted("INCONCLUSIVE", 2, destroyed=False))

    def test_same_expiry_as_this_run_is_not_proof_of_ownership(self):
        """Two plans (e.g. different windows) can produce the same ExpiresAt: without an apply
        attempt, an unexpired environment with this run's ExpiresAt is still protected."""
        rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T21:00:00Z", APPLY_ATTEMPTED="",
                                             OWN_EXPIRES_AT=EXP)
        self.assertEqual((rc, out["decision"], self.destroyed(calls)), (0, "PROTECT", False))

    def test_not_attempted_but_expired_is_destroyed(self):
        rc, text, calls, out = self.run_mode("failure-cleanup", "2026-11-16T23:00:00Z", APPLY_ATTEMPTED="false",
                                             OWN_EXPIRES_AT="2026-11-17T01:00:00Z")
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


class StateSnapshot(unittest.TestCase):
    def test_summary_has_addresses_serial_hashed_lineage_and_expiry_only(self):
        raw = raw_state(STATE, 7)
        raw["resources"].append({"mode": "data", "type": "azurerm_resource_group", "name": "existing",
                                 "instances": [{"index_key": 0, "attributes": {}}]})
        snap = json.loads(snapshot_of(raw))
        self.assertEqual((snap["exists"], snap["serial"], snap["expires_at"]), (True, 7, [EXP]))
        self.assertEqual(len(snap["addresses"]), 12)
        self.assertIn("module.networking.azurerm_network_security_rule.allow_test_sources[0]", snap["addresses"])
        self.assertNotIn("lineage-a", json.dumps(snap))
        self.assertEqual(len(snap["lineage_sha256"]), 64)

    def test_no_state_yet(self):
        self.assertEqual(json.loads(snapshot_of(None))["exists"], False)

    def test_invalid_state_fails(self):
        for text in ("not json", "{}", '{"lineage": "x"}'):
            r = subprocess.run([sys.executable, str(ROOT / "scripts/ci/state_snapshot.py"), "/dev/stdin"],
                               input=text, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
