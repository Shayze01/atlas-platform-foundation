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
                     APPLY_ATTEMPTED=true (this run started terraform apply)        -> DESTROY
                     otherwise (stopped before apply, plan rejected, hash mismatch,
                     approval refused, or unknown), same rules as the sweep, except
                     that resources carrying THIS run's ExpiresAt are this run's
                     and are destroyed. A pre-existing unexpired environment is never
                     destroyed by a run that did not attempt apply.

Usage: expiry_decision.py --mode sweep|failure-cleanup --state STATE_JSON --azure AZURE_JSON
         [--resource-group RG] [--own-expires-at T] [--apply-attempted true|false|""] [--now T]
Prints DECISION=<NOOP|PROTECT|DESTROY|INCONCLUSIVE> and REASON=<text>; exit 0, or 2 for INCONCLUSIVE.
"""
import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

from expiry_map import parse_expiry, reconcile

GRACE = timedelta(minutes=15)
CAP = timedelta(minutes=180)


def decide(report, now, mode, own_expires=None, apply_attempted=""):
    if mode == "failure-cleanup" and apply_attempted == "true":
        return "DESTROY", "this run attempted terraform apply; its workload is destroyed"
    if report["problems"]:
        return "INCONCLUSIVE", "protected - " + "; ".join(report["problems"])
    if not report["entries"]:
        what = "this run created nothing" if mode == "failure-cleanup" else "nothing deployed"
        return "NOOP", f"Terraform state and the workload group are empty ({what})"
    exp_raw = report["expires_at"]
    exp = parse_expiry(exp_raw)
    if exp is None:
        return "INCONCLUSIVE", "protected - no single valid ExpiresAt"
    if mode == "failure-cleanup" and own_expires and exp_raw == own_expires:
        return "DESTROY", f"resources carry this run's ExpiresAt {exp_raw}"
    if exp - now > CAP:
        return "INCONCLUSIVE", f"protected - ExpiresAt {exp_raw} is more than {int(CAP.total_seconds() // 3600)} h ahead (beyond the cap)"
    if now >= exp + GRACE:
        return "DESTROY", f"expired at {exp_raw} (+15 min grace passed)"
    left = int((exp - now).total_seconds() // 60)
    if mode == "failure-cleanup":
        return "PROTECT", (f"pre-existing environment is unexpired (ExpiresAt {exp_raw}, {left} min left) and this "
                           "run did not attempt apply; left in place for its own cleanup")
    return "PROTECT", f"unexpired (ExpiresAt {exp_raw}, {left} min left)"


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["sweep", "failure-cleanup"], required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--azure", required=True)
    p.add_argument("--resource-group", default="rg-atlas-foundation-dev")
    p.add_argument("--own-expires-at", default="")
    p.add_argument("--apply-attempted", default="")
    p.add_argument("--now")
    a = p.parse_args(argv)
    now = parse_expiry(a.now) if a.now else datetime.now(timezone.utc).replace(microsecond=0)
    if a.mode == "failure-cleanup" and a.apply_attempted == "true":
        report = {"problems": [], "entries": [], "expires_at": None}
    else:
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
    decision, reason = decide(report, now, a.mode, a.own_expires_at, a.apply_attempted)
    print(f"DECISION={decision}")
    print(f"REASON={reason}")
    return 2 if decision == "INCONCLUSIVE" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
