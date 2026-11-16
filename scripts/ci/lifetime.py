#!/usr/bin/env python3
"""Environment lifetime: plan-time expiry and the two lifetime gates (no Azure access).

  plan        expires_at = now + approval allowance + lifetime budget (rounded up to the
              minute). Refuses if that exceeds the 3 h cap or if the environment would
              still exist at a safety-net blackout (below).
  pre-apply   first step of apply, before the reviewed plan is fetched: requires the FULL
              budget (provision + tests + inspection + cleanup + margin) to fit before
              expires_at and before the next blackout. Otherwise nothing is created.
  pre-window  just before the inspection window: requires inspection + cleanup + margin.
              If it does not fit, the window is NOT started at all; the requested window
              is never shortened.

Blackouts (an environment must never be alive across them, so a safety net never cuts
into provisioning, a test or your window):
  * auto-shutdown: 02:00 UK local time (Azure "GMT Standard Time" = Europe/London):
    02:00 UTC while the UK is on GMT, 01:00 UTC during British Summer Time;
  * nightly Destroy: 03:30 UTC (destroy.yml cron), guarded from 03:20 UTC.

Budget minutes: provision 20, tests 15, cleanup 20, margin 10, plus inspection
(healthy: 0/15/30/45; deliberate-failure-ignore-status: always 0). Approval allowance 45.

Usage: lifetime.py plan|pre-apply|pre-window --scenario S --inspection-minutes N
                   [--expires-at T] [--now T]
Writes key=value lines to $GITHUB_OUTPUT when set. Exit 0 pass, 1 refused, 2 bad input.
"""
import argparse
import os
import sys
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

PROVISION, TESTS, CLEANUP, MARGIN, APPROVAL = 20, 15, 20, 10, 45
CAP_MINUTES = 180
SCENARIOS = {"healthy": "healthy", "deliberate-failure-ignore-status": "broken-ignore-status"}
WINDOWS = {0, 15, 30, 45}
UK = ZoneInfo("Europe/London")
AUTO_SHUTDOWN_LOCAL = time(2, 0)        # variables.tf auto_shutdown_time "0200", GMT Standard Time
NIGHTLY_DESTROY_UTC = time(3, 30)       # destroy.yml cron "30 3 * * *"
NIGHTLY_GUARD = timedelta(minutes=10)   # never be alive from 03:20 UTC
FMT = "%Y-%m-%dT%H:%M:%SZ"


def parse_utc(value):
    try:
        if len(value) != 20:
            raise ValueError
        return datetime.strptime(value, FMT).replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise ValueError(f"not an exact UTC time YYYY-MM-DDTHH:MM:SSZ: {value!r}")


def fmt(t):
    return t.astimezone(timezone.utc).strftime(FMT)


def effective_inspection(scenario, minutes):
    return 0 if scenario == "deliberate-failure-ignore-status" else minutes


def budget(scenario, minutes):
    return PROVISION + TESTS + effective_inspection(scenario, minutes) + CLEANUP + MARGIN


def blackouts(start, end):
    """Every safety-net instant in (start, end], each with a description."""
    found = []
    day = start.astimezone(UK).date() - timedelta(days=1)
    while datetime.combine(day, time(0), UK) <= end.astimezone(UK) + timedelta(days=1):
        shutdown = datetime.combine(day, AUTO_SHUTDOWN_LOCAL, UK).astimezone(timezone.utc)
        zone = shutdown.astimezone(UK).tzname()
        found.append((shutdown, f"the 02:00 UK auto-shutdown ({shutdown:%H:%M} UTC on {shutdown:%Y-%m-%d}, UK on {zone})"))
        destroy = datetime.combine(day, NIGHTLY_DESTROY_UTC, timezone.utc)
        found.append((destroy - NIGHTLY_GUARD, f"the nightly Destroy at 03:30 UTC on {destroy:%Y-%m-%d} (guarded from 03:20 UTC)"))
        day += timedelta(days=1)
    return sorted((t, d) for t, d in found if start < t <= end)


def next_blackouts(now):
    later = blackouts(now, now + timedelta(days=2))
    shutdown = next(t for t, d in later if "auto-shutdown" in d)
    destroy = next(t for t, d in later if "nightly" in d) + NIGHTLY_GUARD
    return shutdown, destroy


def run(argv, out=print):
    p = argparse.ArgumentParser(description="Atlas environment lifetime gates")
    p.add_argument("phase", choices=["plan", "pre-apply", "pre-window"])
    p.add_argument("--scenario", required=True)
    p.add_argument("--inspection-minutes", required=True)
    p.add_argument("--expires-at")
    p.add_argument("--now")
    a = p.parse_args(argv)
    outputs = {}
    try:
        if a.scenario not in SCENARIOS:
            raise ValueError(f"unknown scenario {a.scenario!r}")
        if not a.inspection_minutes.isdigit() or int(a.inspection_minutes) not in WINDOWS:
            raise ValueError(f"inspection minutes must be one of {sorted(WINDOWS)}, got {a.inspection_minutes!r}")
        minutes = int(a.inspection_minutes)
        now = parse_utc(a.now) if a.now else datetime.now(timezone.utc).replace(microsecond=0)
        if a.phase != "plan":
            if not a.expires_at:
                raise ValueError("--expires-at is required for the gates")
            expires = parse_utc(a.expires_at)
    except ValueError as e:
        out(f"ERROR: {e}")
        return 2, outputs

    window = effective_inspection(a.scenario, minutes)
    if window != minutes:
        out(f"NOTE: inspection window disabled for scenario {a.scenario} (requested {minutes} min, using 0)")
    shutdown, destroy = next_blackouts(now)
    out(f"Now {fmt(now)}; next auto-shutdown {fmt(shutdown)} (02:00 UK, {shutdown.astimezone(UK).tzname()}); "
        f"next nightly Destroy {fmt(destroy)}")

    if a.phase == "plan":
        need = APPROVAL + budget(a.scenario, minutes)
        expires = now + timedelta(minutes=need)
        if expires.second:
            expires += timedelta(seconds=60 - expires.second)
        out(f"Lifetime budget: approval {APPROVAL} + provision {PROVISION} + tests {TESTS} + inspection {window} "
            f"+ cleanup {CLEANUP} + margin {MARGIN} = {need} min")
        end, label = expires, "ExpiresAt " + fmt(expires)
        if need > CAP_MINUTES:
            out(f"REFUSED: {need} min exceeds the {CAP_MINUTES} min cap")
            return 1, outputs
    elif a.phase == "pre-apply":
        need = budget(a.scenario, minutes)
        end = now + timedelta(minutes=need)
        out(f"Pre-apply gate: needs provision {PROVISION} + tests {TESTS} + inspection {window} + cleanup {CLEANUP} "
            f"+ margin {MARGIN} = {need} min (full margin kept)")
        label = f"now + {need} min = {fmt(end)}"
    else:
        need = window + CLEANUP + MARGIN
        end = now + timedelta(minutes=need)
        out(f"Pre-window gate: needs inspection {window} + cleanup {CLEANUP} + margin {MARGIN} = {need} min (full margin kept)")
        label = f"now + {need} min = {fmt(end)}"

    if a.phase != "plan":
        left = (expires - now).total_seconds() / 60
        if end > expires:
            out(f"REFUSED: insufficient lifetime: needs {need} min, {max(left, 0):.0f} min left before ExpiresAt {fmt(expires)}")
            if a.phase == "pre-window":
                out("The inspection window is NOT started; it is never shortened. The environment is destroyed now.")
            outputs["decision"] = "refused"
            return 1, outputs
    crossing = blackouts(now, end)
    if crossing:
        out(f"REFUSED: the environment would still exist at {crossing[0][1]} ({label})")
        if a.phase == "pre-window":
            out("The inspection window is NOT started; it is never shortened. The environment is destroyed now.")
        outputs["decision"] = "refused"
        return 1, outputs

    outputs["decision"] = "pass"
    if a.phase == "plan":
        outputs.update(expires_at=fmt(expires), budget_minutes=str(need), inspection_minutes=str(window))
        out(f"PASS: ExpiresAt {fmt(expires)} is {need} min ahead and before the next safety-net time")
    else:
        out(f"PASS: {need} min fit before ExpiresAt {fmt(expires)} ({(expires - end).total_seconds() / 60:.0f} min spare) "
            "and before the next safety-net time")
    return 0, outputs


def main():
    rc, outputs = run(sys.argv[1:])
    path = os.environ.get("GITHUB_OUTPUT")
    if path and outputs:
        with open(path, "a") as f:
            for k, v in outputs.items():
                f.write(f"{k}={v}\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())
