#!/usr/bin/env python3
"""Expiry-tag carriers and the mapping from Terraform state entries to Azure resources.

Used by the plan policy (every carrier must be planned with ExpiresAt = expires_at) and
by the hourly expiry sweep, which must only ever destroy what it can fully explain.

Each managed Terraform resource type has exactly one role:

  carrier        a top-level Azure resource in the workload group that carries the
                 ExpiresAt tag (VNet, NSG, public IP, NIC, VM, auto-shutdown schedule)
  child          an Azure sub-resource or property with no tags of its own, covered by
                 its parent carrier: subnet and NSG/subnet association -> VNet,
                 NSG rules -> NSG
  (managed child) the VM's OS disk: a top-level Azure resource (Microsoft.Compute/disks)
                 that is NOT a Terraform resource and is not tagged by the VM; it is
                 explained by, and deleted with, the VM entry
  persistent     never managed by the workload state (resource group); its presence in
                 state is a problem
  data sources   read-only lookups, ignored

Anything not explainable this way is a problem, and a problem means PROTECT: the sweep
never destroys on uncertainty. CLI: expiry_map.py STATE_JSON AZURE_JSON RESOURCE_GROUP
(STATE_JSON from `terraform show -json`, AZURE_JSON from `az resource list -g RG -o json`)
prints a JSON report; exit 0 no problems, 2 problems, 3 unreadable input.
"""
import json
import re
import sys
from datetime import datetime, timezone

TAG = "ExpiresAt"
EXPIRY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

CARRIERS = {
    "azurerm_virtual_network": "Microsoft.Network/virtualNetworks",
    "azurerm_network_security_group": "Microsoft.Network/networkSecurityGroups",
    "azurerm_public_ip": "Microsoft.Network/publicIPAddresses",
    "azurerm_network_interface": "Microsoft.Network/networkInterfaces",
    "azurerm_linux_virtual_machine": "Microsoft.Compute/virtualMachines",
    "azurerm_dev_test_global_vm_shutdown_schedule": "Microsoft.DevTestLab/schedules",
}
# child type -> regex removing the child part of its Azure ID to give the parent carrier ID
CHILDREN = {
    "azurerm_subnet": re.compile(r"/subnets/[^/]+$", re.I),
    "azurerm_subnet_network_security_group_association": re.compile(r"/subnets/[^/]+$", re.I),
    "azurerm_network_security_rule": re.compile(r"/securityRules/[^/]+$", re.I),
}
PERSISTENT = {"azurerm_resource_group"}
MANAGED_CHILD_TYPE = "Microsoft.Compute/disks"


def parse_expiry(value):
    """Return an aware datetime for an exact YYYY-MM-DDTHH:MM:SSZ real UTC time, else None."""
    if not isinstance(value, str) or not EXPIRY_RE.match(value):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def walk(module):
    for r in (module or {}).get("resources") or []:
        yield r
    for child in (module or {}).get("child_modules") or []:
        yield from walk(child)


def norm(azure_id):
    return str(azure_id or "").rstrip("/").lower()


def map_state(state, resource_group):
    """Map every managed state entry to its role and top-level Azure ID."""
    entries, problems = [], []
    root = ((state or {}).get("values") or {}).get("root_module")
    for r in walk(root):
        addr, rtype, mode = r.get("address", "?"), r.get("type"), r.get("mode", "managed")
        if mode == "data":
            continue
        v = r.get("values") or {}
        rid = v.get("id")
        if rtype in PERSISTENT:
            problems.append(f"persistent resource {addr} is in the workload state (would be destroyed)")
            continue
        if not rid:
            problems.append(f"{addr}: no Azure ID in state")
            continue
        if f"/resourcegroups/{resource_group.lower()}/" not in norm(rid):
            problems.append(f"{addr}: Azure ID is outside {resource_group}")
            continue
        if rtype in CARRIERS:
            tags = v.get("tags") or {}
            entry = {"address": addr, "type": rtype, "role": "carrier", "azure_id": norm(rid),
                     "state_tag": tags.get(TAG)}
            entries.append(entry)
            if rtype == "azurerm_linux_virtual_machine":
                disk = ((v.get("os_disk") or [{}])[0] or {}).get("name")
                if not disk:
                    problems.append(f"{addr}: OS disk name missing in state")
                else:
                    base = norm(rid).split("/providers/")[0]
                    entries.append({"address": f"{addr}.os_disk[0]", "type": "managed OS disk",
                                    "role": "managed-child",
                                    "azure_id": f"{base}/providers/{MANAGED_CHILD_TYPE.lower()}/{disk.lower()}",
                                    "parent": norm(rid)})
        elif rtype in CHILDREN:
            parent = CHILDREN[rtype].sub("", norm(rid))
            if parent == norm(rid):
                problems.append(f"{addr}: cannot derive the parent of {rtype}")
                continue
            entries.append({"address": addr, "type": rtype, "role": "child", "azure_id": parent})
        else:
            problems.append(f"{addr}: unknown resource type {rtype} (no expiry mapping)")
    return entries, problems


def reconcile(state, azure_resources, resource_group):
    """Compare state with the Azure resources in the group and read the carrier tags."""
    entries, problems = map_state(state, resource_group)
    if not isinstance(azure_resources, list):
        return {"entries": entries, "carriers": {}, "expires_at": None,
                "problems": problems + ["Azure resource list is not a list"]}
    azure = {}
    for res in azure_resources:
        rid = norm((res or {}).get("id"))
        if not rid:
            problems.append("an Azure resource has no ID")
            continue
        azure[rid] = res
    carriers = {e["azure_id"]: e for e in entries if e["role"] == "carrier"}
    explained = set(carriers) | {e["azure_id"] for e in entries if e["role"] == "managed-child"}
    for e in entries:
        if e["role"] == "child" and e["azure_id"] not in carriers:
            problems.append(f"{e['address']}: parent {e['azure_id']} is not a carrier in state")
    for rid in sorted(explained - set(azure)):
        problems.append(f"in state but not in Azure: {rid}")
    for rid in sorted(set(azure) - explained):
        problems.append(f"in Azure but not explained by state: {rid}")

    values = {}
    for rid, e in sorted(carriers.items()):
        if rid not in azure:
            continue
        tags = azure[rid].get("tags")
        tag = tags.get(TAG) if isinstance(tags, dict) else None
        if tag is None:
            problems.append(f"missing {TAG} tag on {rid}")
            continue
        if parse_expiry(tag) is None:
            problems.append(f"malformed {TAG} tag on {rid}: {tag!r}")
            continue
        if e.get("state_tag") != tag:
            problems.append(f"{TAG} on {rid} differs between Azure ({tag}) and state ({e.get('state_tag')})")
        values[rid] = tag
    distinct = sorted(set(values.values()))
    if len(distinct) > 1:
        problems.append(f"conflicting {TAG} values across carriers: {', '.join(distinct)}")
    expires = distinct[0] if len(distinct) == 1 and not problems else None
    return {"entries": entries, "carriers": values, "expires_at": expires, "problems": problems}


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[0]); print("usage: expiry_map.py STATE_JSON AZURE_JSON RESOURCE_GROUP")
        return 3
    try:
        with open(argv[1]) as f:
            state = json.load(f)
        with open(argv[2]) as f:
            azure = json.load(f)
    except (OSError, ValueError) as e:
        print(json.dumps({"problems": [f"unreadable input: {e.__class__.__name__}"]}))
        return 3
    report = reconcile(state, azure, argv[3])
    print(json.dumps(report, indent=2))
    return 2 if report["problems"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
