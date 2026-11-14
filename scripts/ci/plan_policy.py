#!/usr/bin/env python3
"""Allowlisted deployment details and policy checks for a saved Terraform plan.

Reads `terraform show -json <plan>` on stdin and prints a Markdown section with ONLY
allowlisted values (VM size, region, OS disk type, image, password-auth status,
auto-shutdown settings, counts of inbound sources). Addresses, keys, IDs, custom_data
and any other attribute are never printed.

Policy checks run against planned_values (the desired end state, so they also apply
to no-change plans). FAIL CLOSED: a check that cannot be evaluated (missing/unknown
value, unexpected structure) counts as a failure.

Exit: 0 every check passed; 1 a check failed or could not be evaluated; 2 bad input.
Environment: EXPECTED_VM_SIZE (Standard_B2ats_v2), EXPECTED_SHUTDOWN_TIME (0200),
EXPECTED_SHUTDOWN_TZ (GMT Standard Time).
"""
import json
import os
import re
import sys

EXPECTED_VM_SIZE = os.environ.get("EXPECTED_VM_SIZE", "Standard_B2ats_v2")
EXPECTED_SHUTDOWN_TIME = os.environ.get("EXPECTED_SHUTDOWN_TIME", "0200")
EXPECTED_SHUTDOWN_TZ = os.environ.get("EXPECTED_SHUTDOWN_TZ", "GMT Standard Time")
TEMP_RULE = "Allow-SSH-HTTP-From-Test-Temporary"
OCTET = r"(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"
CIDR32 = re.compile(rf"^{OCTET}(\.{OCTET}){{3}}/32$")
OPEN_SOURCES = {"*", "0.0.0.0/0", "0.0.0.0", "internet", "any"}


class Unknown(Exception):
    pass


def walk(module):
    for r in module.get("resources") or []:
        yield r
    for child in module.get("child_modules") or []:
        yield from walk(child)


def val(values, key):
    if not isinstance(values, dict) or values.get(key) is None:
        raise Unknown(key)
    return values[key]


def main():
    try:
        plan = json.load(sys.stdin)
    except (ValueError, UnicodeDecodeError):
        print("ERROR: plan JSON is malformed")
        return 2
    root = (plan.get("planned_values") or {}).get("root_module") if isinstance(plan, dict) else None
    checks, details = [], []

    def check(name, fn):
        try:
            ok, detail = fn()
            checks.append((name, "PASS" if ok else "FAIL", detail))
        except Unknown as e:
            checks.append((name, "UNEVALUABLE", f"value `{e}` missing or unknown at plan time"))
        except (TypeError, KeyError, AttributeError, IndexError):
            checks.append((name, "UNEVALUABLE", "unexpected plan structure"))

    if not isinstance(root, dict):
        print("#### Deployment policy (fail closed)\n\n| Check | Result | Detail |\n| --- | --- | --- |")
        print("| planned_values present | UNEVALUABLE | the plan has no planned_values |")
        print("\nPOLICY FAILED: the plan is not offered for approval.")
        return 1

    res = [r for r in walk(root) if isinstance(r, dict)]
    of = lambda t: [r for r in res if r.get("type") == t]  # noqa: E731
    vms = of("azurerm_linux_virtual_machine")
    schedules = of("azurerm_dev_test_global_vm_shutdown_schedule")
    rules = [r.get("values") or {} for r in of("azurerm_network_security_rule")]
    subnets = of("azurerm_subnet")

    def one_vm():
        if len(vms) != 1:
            raise Unknown("azurerm_linux_virtual_machine (expected exactly 1)")
        return vms[0].get("values") or {}

    def vm_size():
        size = val(one_vm(), "size")
        details.append(("VM size", f"`{size}`"))
        return size == EXPECTED_VM_SIZE, f"`{size}` (expected `{EXPECTED_VM_SIZE}`)"

    def region():
        loc = val(one_vm(), "location")
        details.append(("Region", f"`{loc}`"))
        return True, f"`{loc}`"

    def disk():
        osd = val(one_vm(), "os_disk")
        kind = val(osd[0], "storage_account_type")
        details.append(("OS disk type", f"`{kind}`"))
        return True, f"`{kind}`"

    def password():
        disabled = val(one_vm(), "disable_password_authentication")
        details.append(("Password authentication", "disabled" if disabled is True else "**ENABLED**"))
        return disabled is True, "disabled (SSH keys only)" if disabled is True else "password logins would be allowed"

    def shutdown():
        if len(schedules) != 1:
            details.append(("Auto-shutdown", "**not configured**"))
            return False, f"expected exactly 1 schedule, found {len(schedules)}"
        v = schedules[0].get("values") or {}
        en, t, tz = val(v, "enabled"), val(v, "daily_recurrence_time"), val(v, "timezone")
        details.append(("Auto-shutdown", f"{'enabled' if en else 'DISABLED'}, {t} `{tz}`"))
        ok = en is True and t == EXPECTED_SHUTDOWN_TIME and tz == EXPECTED_SHUTDOWN_TZ
        return ok, f"{'enabled' if en else 'disabled'} at {t} {tz} (expected {EXPECTED_SHUTDOWN_TIME} {EXPECTED_SHUTDOWN_TZ})"

    def inbound_sources():
        allows = [r for r in rules if r.get("access") == "Allow" and r.get("direction") == "Inbound"]
        if not allows:
            raise Unknown("inbound Allow rules (none found)")
        parts, bad = [], 0
        for r in allows:
            single = r.get("source_address_prefix")
            srcs = [single] if single else (r.get("source_address_prefixes") or [])
            if not srcs:
                raise Unknown(f"source of rule {r.get('name', '?')}")
            ports = r.get("destination_port_range") or ",".join(r.get("destination_port_ranges") or []) or "?"
            for s in srcs:
                if str(s).lower() in OPEN_SOURCES or not CIDR32.match(str(s)):
                    bad += 1
            parts.append(f"port {ports} from {len(srcs)} source(s)")
        details.append(("Inbound allow rules", f"{len(allows)}: " + "; ".join(parts)))
        if bad:
            return False, f"{bad} source(s) are internet-wide or wider than a single IPv4 /32"
        return True, f"all {len(allows)} inbound allow rule(s) use single IPv4 /32 sources"

    def deny_internet():
        ok = any(r.get("access") == "Deny" and r.get("direction") == "Inbound"
                 and str(r.get("source_address_prefix", "")).lower() == "internet" for r in rules)
        return ok, "explicit inbound Internet deny present" if ok else "no inbound Internet deny rule"

    def no_temp_rule():
        present = any(r.get("name") == TEMP_RULE for r in rules)
        return not present, "absent" if not present else f"{TEMP_RULE} would exist (test_source_ip_cidrs not empty)"

    def explicit_outbound():
        if len(subnets) != 1:
            raise Unknown("azurerm_subnet (expected exactly 1)")
        v = (subnets[0].get("values") or {})
        if "default_outbound_access_enabled" not in v or v["default_outbound_access_enabled"] is None:
            raise Unknown("default_outbound_access_enabled")
        off = v["default_outbound_access_enabled"] is False
        return off, "subnet default outbound access disabled (egress via the NIC's public IP)" if off else "implicit default outbound access enabled"

    check("VM size is the approved small size", vm_size)
    check("Region known", region)
    check("OS disk type known", disk)
    check("Password authentication disabled", password)
    check("Daily auto-shutdown at the approved UK time", shutdown)
    check("Inbound allow rules use single /32 sources only (no internet-wide SSH/HTTP)", inbound_sources)
    check("Explicit inbound Internet deny", deny_internet)
    check("No temporary test rule in the deployed configuration", no_temp_rule)
    check("No implicit outbound access", explicit_outbound)

    print("#### Deployment details (allowlisted values only)\n")
    print("| Setting | Planned value |\n| --- | --- |")
    for k, v in details:
        print(f"| {k} | {v} |")
    print("\n#### Deployment policy (fail closed)\n")
    print("| Check | Result | Detail |\n| --- | --- | --- |")
    for name, status, detail in checks:
        print(f"| {name} | {status} | {detail} |")
    failed = [c for c in checks if c[1] != "PASS"]
    print()
    if failed:
        print(f"POLICY FAILED: {len(failed)} check(s) failed or could not be evaluated; the plan is not offered for approval.")
        return 1
    print(f"Policy checks: {len(checks)} passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
