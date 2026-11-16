#!/usr/bin/env python3
"""Decides whether a guarded cleanup may destroy the workload. Never destroys on uncertainty.

Modes
  sweep            hourly expiry sweep (destroy.yml), revision 2 section 6.3:
                     problems (missing/malformed/conflicting/mismatched tags, state and
                     Azure disagree, unknown types, persistent resources in state)  -> INCONCLUSIVE (2)
                     state and group empty                                          -> NOOP (0)
                     ExpiresAt more than the 3 h cap ahead                          -> INCONCLUSIVE (2)
                     now >= ExpiresAt + 15 min                                      -> DESTROY (0)
                     otherwise (unexpired)                                          -> PROTECT (0)
  failure-cleanup  deploy.yml after apply failed / was cancelled / was not approved:
                     not attempted (stopped before apply, plan rejected, hash mismatch,
                     approval refused, or unknown): exactly the sweep rules. An
                     unexpired environment is never destroyed by a run that did not
                     attempt apply - not even one whose ExpiresAt equals this run's,
                     because two plans can produce the same ExpiresAt.
                   APPLY_ATTEMPTED=true: an attempt alone proves nothing (apply can be
                   refused by a state lock or a stale plan before changing anything), so
                   ownership is derived from the pre-apply and current state snapshots
                   (state_snapshot.py) plus the full state/Azure reconcile:
                     state persistence failed, snapshot missing/unreadable, lineage
                     changed, serial went backwards, any reconcile problem          -> INCONCLUSIVE
                     serial unchanged (Terraform recorded no change) and state equal
                     to the snapshot: the sweep rules (unexpired -> PROTECT). Azure is
                     not assumed untouched: unrecorded Azure changes show up as
                     reconcile problems                                             -> INCONCLUSIVE
                     serial changed, pre-apply state empty: every resource was
                     created by this run and carries this run's ExpiresAt           -> DESTROY
                     serial changed, pre-existing environment: a changed serial does
                     not make it this run's; destroyed only if that environment had
                     itself expired (+15 min), else                                 -> INCONCLUSIVE

Usage: expiry_decision.py --mode sweep|failure-cleanup --state STATE_JSON --azure AZURE_JSON
         [--resource-group RG] [--own-expires-at T] [--apply-attempted true|false|""] [--now T]
         [--pre-snapshot FILE] [--post-snapshot FILE] [--apply-error KIND]
Prints DECISION=<NOOP|PROTECT|DESTROY|INCONCLUSIVE> and REASON=<text>; exit 0, or 2 for INCONCLUSIVE.
"""
import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

from expiry_map import parse_expiry, reconcile

GRACE = timedelta(minutes=15)
CAP = timedelta(minutes=180)


RECOVERY = "manual recovery required (docs/milestone-3.md, 'Manual recovery')"


def decide(report, now, mode, own_expires=None, apply_attempted="", why="this run did not attempt apply"):
    if report["problems"]:
        return "INCONCLUSIVE", "protected - " + "; ".join(report["problems"])
    if not report["entries"]:
        what = "this run created nothing" if mode == "failure-cleanup" else "nothing deployed"
        return "NOOP", f"Terraform state and the workload group are empty ({what})"
    exp_raw = report["expires_at"]
    exp = parse_expiry(exp_raw)
    if exp is None:
        return "INCONCLUSIVE", "protected - no single valid ExpiresAt"
    if exp - now > CAP:
        return "INCONCLUSIVE", f"protected - ExpiresAt {exp_raw} is more than {int(CAP.total_seconds() // 3600)} h ahead (beyond the cap)"
    if now >= exp + GRACE:
        return "DESTROY", f"expired at {exp_raw} (+15 min grace passed)"
    left = int((exp - now).total_seconds() // 60)
    if mode == "failure-cleanup":
        return "PROTECT", (f"environment is unexpired (ExpiresAt {exp_raw}, {left} min left) and "
                           f"{why}; left in place for its own cleanup (in-job destroy, sweep, nightly Destroy)")
    return "PROTECT", f"unexpired (ExpiresAt {exp_raw}, {left} min left)"


def valid_snapshot(snap):
    return (isinstance(snap, dict) and isinstance(snap.get("exists"), bool)
            and isinstance(snap.get("lineage_sha256"), str) and isinstance(snap.get("addresses"), list)
            and isinstance(snap.get("expires_at"), list)
            and (snap.get("serial") is None if not snap["exists"] else
                 isinstance(snap.get("serial"), int) and not isinstance(snap.get("serial"), bool)))


def decide_attempted(report, now, own_expires, pre, post, apply_error=""):
    """failure-cleanup after this run started terraform apply. Never destroys on uncertainty."""
    inc = "INCONCLUSIVE"
    if apply_error == "state-persist-failed":
        return inc, ("protected - terraform apply could not persist state: Azure may hold resources missing "
                     f"from state; {RECOVERY}")
    if not valid_snapshot(pre):
        return inc, f"protected - no valid pre-apply state snapshot, so ownership is unknown; {RECOVERY}"
    if not valid_snapshot(post):
        return inc, f"protected - current state snapshot unreadable; {RECOVERY}"
    if pre["exists"] and (not post["exists"] or post["lineage_sha256"] != pre["lineage_sha256"]):
        return inc, f"protected - state lineage changed since before apply (state replaced); {RECOVERY}"
    if pre["exists"] and post["serial"] < pre["serial"]:
        return inc, f"protected - state serial went backwards ({pre['serial']} -> {post['serial']}); {RECOVERY}"
    if report["problems"]:
        return inc, "protected after an apply attempt - " + "; ".join(report["problems"]) + f"; {RECOVERY}"
    state_addrs = sorted(e["address"] for e in report["entries"] if e["role"] != "managed-child")
    if state_addrs != sorted(post["addresses"]):
        return inc, f"protected - state changed while it was being read; {RECOVERY}"
    changed = post["exists"] and (not pre["exists"] or post["serial"] != pre["serial"])
    kind = f" ({apply_error})" if apply_error else ""
    if not changed:
        if sorted(post["addresses"]) != sorted(pre["addresses"]) or sorted(post["expires_at"]) != sorted(pre["expires_at"]):
            return inc, f"protected - state differs from the pre-apply snapshot although its serial did not change; {RECOVERY}"
        return decide(report, now, "failure-cleanup",
                      why=f"terraform apply recorded no change{kind}, so this run does not own it")
    if not report["entries"]:
        return "NOOP", "terraform apply recorded changes, but the state and the workload group are now empty"
    exp_raw = report["expires_at"]
    if not pre["addresses"]:
        if exp_raw != own_expires:
            return inc, (f"protected - resources in state carry ExpiresAt {exp_raw}, not this run's {own_expires}, "
                         f"although the pre-apply state was empty; {RECOVERY}")
        return "DESTROY", ("every workload resource was created by this run (the pre-apply state was empty) "
                           f"and carries this run's ExpiresAt {own_expires}")
    pre_exp = parse_expiry(pre["expires_at"][0]) if len(pre["expires_at"]) == 1 else None
    if pre_exp is not None and now >= pre_exp + GRACE and exp_raw in (pre["expires_at"][0], own_expires):
        return "DESTROY", (f"the pre-existing environment had expired at {pre['expires_at'][0]} (+15 min grace passed); "
                           "everything else was created or updated by this run")
    what = pre["expires_at"][0] if len(pre["expires_at"]) == 1 else "unknown or conflicting"
    return inc, (f"protected - terraform apply{kind} changed a pre-existing environment (ExpiresAt {what}, "
                 f"not expired); a changed serial does not make it this run's; {RECOVERY}")


def load_snapshot(path):
    if not path:
        return None
    try:
        with open(path) as f:
            text = f.read()
        return json.loads(text) if text.strip() else None
    except (OSError, ValueError):
        return None


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["sweep", "failure-cleanup"], required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--azure", required=True)
    p.add_argument("--resource-group", default="rg-atlas-foundation-dev")
    p.add_argument("--own-expires-at", default="")
    p.add_argument("--apply-attempted", default="")
    p.add_argument("--now")
    p.add_argument("--pre-snapshot", default="")
    p.add_argument("--post-snapshot", default="")
    p.add_argument("--apply-error", default="")
    a = p.parse_args(argv)
    now = parse_expiry(a.now) if a.now else datetime.now(timezone.utc).replace(microsecond=0)
    try:
        with open(a.state) as f:
            state = json.load(f)
        with open(a.azure) as f:
            azure = json.load(f)
    except (OSError, ValueError) as e:
        print("DECISION=INCONCLUSIVE")
        print(f"REASON=protected - state or Azure resource list unreadable ({e.__class__.__name__})")
        return 2
    report = reconcile(state, azure, a.resource_group)
    if a.mode == "failure-cleanup" and a.apply_attempted == "true":
        decision, reason = decide_attempted(report, now, a.own_expires_at, load_snapshot(a.pre_snapshot),
                                            load_snapshot(a.post_snapshot), a.apply_error)
    else:
        decision, reason = decide(report, now, a.mode, a.own_expires_at, a.apply_attempted)
    print(f"DECISION={decision}")
    print(f"REASON={reason}")
    return 2 if decision == "INCONCLUSIVE" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
