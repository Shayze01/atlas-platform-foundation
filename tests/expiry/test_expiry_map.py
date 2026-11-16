#!/usr/bin/env python3
"""Offline tests for scripts/ci/expiry_map.py against a representative complete deployment.

The fixtures model every Terraform state entry of a full deployment (including the
temporary runner rule, all NSG rules, the subnet/NSG association and the data source)
and the matching `az resource list` output, including the VM's untagged OS disk.
"""
import copy
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import expiry_map as em  # noqa: E402

FIX = ROOT / "tests" / "expiry" / "fixtures"
RG = "rg-atlas-foundation-dev"
EXP = "2026-11-16T22:35:00Z"
STATE = json.loads((FIX / "state-full-deployment.json").read_text())
AZURE = json.loads((FIX / "azure-full-deployment.json").read_text())


def state_resources(state):
    return list(em.walk(state["values"]["root_module"]))


def azure_by_suffix(azure, suffix):
    return next(r for r in azure if r["id"].lower().endswith(suffix.lower()))


class FullDeployment(unittest.TestCase):
    def setUp(self):
        self.state, self.azure = copy.deepcopy(STATE), copy.deepcopy(AZURE)

    def run_map(self):
        return em.reconcile(self.state, self.azure, RG)

    def test_complete_deployment_is_fully_explained(self):
        rep = self.run_map()
        self.assertEqual(rep["problems"], [])
        self.assertEqual(rep["expires_at"], EXP)
        roles = {e["address"]: e["role"] for e in rep["entries"]}
        self.assertEqual(len(roles), 13, roles)  # 12 managed state entries + the VM's OS disk
        self.assertEqual(sorted(a for a, r in roles.items() if r == "carrier"), sorted([
            "module.networking.azurerm_virtual_network.this",
            "module.networking.azurerm_network_security_group.workload",
            "module.compute.azurerm_public_ip.vm",
            "module.compute.azurerm_network_interface.vm",
            "module.compute.azurerm_linux_virtual_machine.this",
            "module.compute.azurerm_dev_test_global_vm_shutdown_schedule.this[0]",
        ]))
        self.assertEqual(len(rep["carriers"]), 6)
        self.assertNotIn("data.azurerm_resource_group.existing[0]", roles)

    def test_children_map_to_their_parent_carrier(self):
        rep = self.run_map()
        by = {e["address"]: e for e in rep["entries"]}
        nsg = by["module.networking.azurerm_network_security_group.workload"]["azure_id"]
        vnet = by["module.networking.azurerm_virtual_network.this"]["azure_id"]
        vm = by["module.compute.azurerm_linux_virtual_machine.this"]["azure_id"]
        for name in ["allow_ssh_from_admin", "allow_http_from_admin", "allow_test_sources[0]", "deny_internet_inbound"]:
            e = by[f"module.networking.azurerm_network_security_rule.{name}"]
            self.assertEqual((e["role"], e["azure_id"]), ("child", nsg), name)
        self.assertEqual(by["module.networking.azurerm_subnet.workload"]["azure_id"], vnet)
        self.assertEqual(by["module.networking.azurerm_subnet_network_security_group_association.workload"]["azure_id"], vnet)
        disk = by["module.compute.azurerm_linux_virtual_machine.this.os_disk[0]"]
        self.assertEqual((disk["role"], disk["parent"]), ("managed-child", vm))
        self.assertTrue(disk["azure_id"].endswith("/microsoft.compute/disks/osdisk-atlas-foundation-dev"))

    def test_untagged_os_disk_is_not_a_carrier(self):
        self.assertIsNone(azure_by_suffix(self.azure, "/disks/osdisk-atlas-foundation-dev")["tags"])
        self.assertEqual(self.run_map()["problems"], [])

    def test_azure_id_case_differences_are_tolerated(self):
        for r in self.azure:
            r["id"] = r["id"].upper()
        self.assertEqual(self.run_map()["problems"], [])

    # ---- protect on uncertainty: every case below must report a problem and no expiry
    def assert_protects(self, pattern):
        rep = self.run_map()
        self.assertIsNone(rep["expires_at"])
        self.assertTrue(any(re.search(pattern, p) for p in rep["problems"]), rep["problems"])

    def test_missing_tag(self):
        del azure_by_suffix(self.azure, "/publicIPAddresses/pip-atlas-foundation-dev")["tags"]["ExpiresAt"]
        self.assert_protects(r"missing ExpiresAt tag on .*publicipaddresses")

    def test_tags_absent_entirely(self):
        azure_by_suffix(self.azure, "/networkInterfaces/nic-atlas-foundation-dev")["tags"] = None
        self.assert_protects(r"missing ExpiresAt tag")

    def test_malformed_tags(self):
        for bad in ["2026-11-16 22:35", "2026-11-16T22:35:00+00:00", "2026-02-30T10:00:00Z", "", "tomorrow"]:
            with self.subTest(bad=bad):
                self.setUp()
                azure_by_suffix(self.azure, "/virtualMachines/vm-atlas-foundation-dev")["tags"]["ExpiresAt"] = bad
                self.assert_protects(r"malformed ExpiresAt")

    def test_conflicting_tags(self):
        for r in self.azure:
            if r["id"].lower().endswith("/nsg-atlas-foundation-dev"):
                r["tags"]["ExpiresAt"] = "2026-11-16T23:35:00Z"
        for r in state_resources(self.state):
            if r["type"] == "azurerm_network_security_group":
                r["values"]["tags"]["ExpiresAt"] = "2026-11-16T23:35:00Z"
        self.assert_protects(r"conflicting ExpiresAt values")

    def test_state_and_azure_tag_mismatch(self):
        azure_by_suffix(self.azure, "/virtualNetworks/vnet-atlas-foundation-dev")["tags"]["ExpiresAt"] = "2026-11-16T23:59:00Z"
        self.assert_protects(r"differs between Azure .* and state")

    def test_resource_in_azure_not_in_state(self):
        extra = copy.deepcopy(self.azure[0])
        extra["id"] = extra["id"].rsplit("/", 2)[0] + "/virtualNetworks/vnet-created-by-hand"
        self.azure.append(extra)
        self.assert_protects(r"in Azure but not explained by state: .*vnet-created-by-hand")

    def test_resource_in_state_not_in_azure(self):
        self.azure = [r for r in self.azure if "/networkInterfaces/" not in r["id"]]
        self.assert_protects(r"in state but not in Azure: .*networkinterfaces")

    def test_os_disk_missing_from_azure(self):
        self.azure = [r for r in self.azure if "/disks/" not in r["id"]]
        self.assert_protects(r"in state but not in Azure: .*disks")

    def test_unknown_resource_type(self):
        self.state["values"]["root_module"]["child_modules"][1]["resources"].append(
            {"address": "module.compute.azurerm_managed_disk.data", "mode": "managed", "type": "azurerm_managed_disk",
             "values": {"id": self.azure[0]["id"].rsplit("/", 2)[0].replace("Microsoft.Network", "Microsoft.Compute") + "/disks/data"}})
        self.assert_protects(r"unknown resource type azurerm_managed_disk")

    def test_resource_group_in_state_is_never_accepted(self):
        self.state["values"]["root_module"]["resources"].append(
            {"address": "azurerm_resource_group.this[0]", "mode": "managed", "type": "azurerm_resource_group",
             "values": {"id": f"/subscriptions/x/resourceGroups/{RG}"}})
        self.assert_protects(r"persistent resource azurerm_resource_group")

    def test_state_entry_outside_the_workload_group(self):
        r = state_resources(self.state)[1]
        r["values"]["id"] = r["values"]["id"].replace(RG, "rg-atlas-tfstate")
        self.assert_protects(r"outside rg-atlas-foundation-dev")

    def test_azure_list_unreadable(self):
        self.azure = {"error": "AuthorizationFailed"}
        self.assert_protects(r"not a list")

    def test_empty_state_and_empty_group(self):
        rep = em.reconcile({"values": {"root_module": {}}}, [], RG)
        self.assertEqual((rep["entries"], rep["problems"], rep["expires_at"]), ([], [], None))

    def test_empty_state_but_resources_in_group(self):
        rep = em.reconcile({"values": {"root_module": {}}}, self.azure, RG)
        self.assertEqual(len([p for p in rep["problems"] if p.startswith("in Azure but not explained")]), 7)


class MappingCoversTheConfiguration(unittest.TestCase):
    """Drift guard: every resource declared in Terraform is mapped and in the fixture."""

    def declared(self):
        found = set()
        for tf, prefix in [(ROOT / "main.tf", ""), (ROOT / "modules/networking/main.tf", "module.networking."),
                           (ROOT / "modules/compute/main.tf", "module.compute.")]:
            for kind, rtype, name in re.findall(r'^(resource|data) "([a-z0-9_]+)" "([a-z0-9_]+)"', tf.read_text(), re.M):
                found.add((kind, rtype, f"{prefix}{'data.' if kind == 'data' else ''}{rtype}.{name}"))
        return found

    def test_every_declared_resource_type_has_a_role(self):
        for kind, rtype, addr in self.declared():
            if kind == "resource":
                self.assertIn(rtype, set(em.CARRIERS) | set(em.CHILDREN) | em.PERSISTENT, addr)

    def test_fixture_contains_every_workload_resource(self):
        fixture = {re.sub(r"\[\d+\]", "", r["address"]) for r in state_resources(STATE)}
        for kind, rtype, addr in self.declared():
            if kind == "resource" and rtype not in em.PERSISTENT:
                self.assertIn(addr, fixture)

    def test_every_carrier_type_is_tagged_from_common_tags(self):
        text = (ROOT / "modules/networking/main.tf").read_text() + (ROOT / "modules/compute/main.tf").read_text()
        for rtype in em.CARRIERS:
            block = re.search(rf'resource "{rtype}" "[a-z_]+" {{(.*?)\n}}', text, re.S).group(1)
            self.assertRegex(block, r"\n  tags\s+= var\.tags", rtype)
        self.assertIn("ExpiresAt  = var.expires_at", (ROOT / "locals.tf").read_text())


class Cli(unittest.TestCase):
    def cli(self, state, azure):
        with tempfile.TemporaryDirectory() as d:
            s, a = pathlib.Path(d, "s.json"), pathlib.Path(d, "a.json")
            s.write_text(state), a.write_text(azure)
            return subprocess.run([sys.executable, ROOT / "scripts/ci/expiry_map.py", s, a, RG], capture_output=True, text=True)

    def test_exit_codes(self):
        self.assertEqual(self.cli(json.dumps(STATE), json.dumps(AZURE)).returncode, 0)
        self.assertEqual(self.cli(json.dumps(STATE), "[]").returncode, 2)
        self.assertEqual(self.cli("{not json", "[]").returncode, 3)


class ParseExpiry(unittest.TestCase):
    def test_only_exact_real_utc_times(self):
        self.assertIsNotNone(em.parse_expiry(EXP))
        for bad in [None, 5, "2026-11-16T22:35:00", "2026-11-16T22:35Z", "2026-13-01T00:00:00Z", " 2026-11-16T22:35:00Z"]:
            self.assertIsNone(em.parse_expiry(bad), bad)


if __name__ == "__main__":
    unittest.main(verbosity=2)
