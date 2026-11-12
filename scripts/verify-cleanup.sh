#!/usr/bin/env bash
# Read-only check that THIS project's resources are gone after 'terraform destroy'.
# It only queries the project's own resource group and exact resource names, so
# other Project Atlas resources in the subscription are never listed or touched.
#
# Usage: ./scripts/verify-cleanup.sh [name-suffix]
#   name-suffix defaults to atlas-foundation-dev (project_name-environment).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SUFFIX="${1:-atlas-foundation-dev}"
RG="rg-${SUFFIX}"
remaining=0

echo "Subscription: $(az account show --query name --output tsv)"
echo "Project resource group: ${RG}"

echo; echo "==> Terraform state (run from this repository)"
if [[ -n "$(terraform state list 2>/dev/null)" ]]; then
  echo "FAIL: Terraform state still tracks resources:"; terraform state list
  remaining=$((remaining + 1))
else
  echo "PASS: Terraform state tracks no resources"
fi

echo; echo "==> Resource group"
if [[ "$(az group exists --name "${RG}")" == "true" ]]; then
  echo "FAIL: ${RG} still exists. Resources inside it:"
  az resource list --resource-group "${RG}" --query "[].{name:name, type:type}" --output table
  remaining=$((remaining + 1))
else
  echo "PASS: ${RG} does not exist"
fi

echo; echo "==> Exact project resource names"
# Each resource lives inside the project resource group, so if the group is gone
# these lookups return 'not found'. They are listed explicitly for evidence.
check_absent() {
  local type="$1" name="$2"
  if az resource show --resource-group "${RG}" --resource-type "${type}" --name "${name}" >/dev/null 2>&1; then
    echo "FAIL: ${type}/${name} still exists"
    remaining=$((remaining + 1))
  else
    echo "PASS: ${type}/${name} not found"
  fi
}
check_absent Microsoft.Compute/virtualMachines        "vm-${SUFFIX}"
check_absent Microsoft.Compute/disks                  "osdisk-${SUFFIX}"
check_absent Microsoft.Network/networkInterfaces      "nic-${SUFFIX}"
check_absent Microsoft.Network/publicIPAddresses      "pip-${SUFFIX}"
check_absent Microsoft.Network/networkSecurityGroups  "nsg-${SUFFIX}"
check_absent Microsoft.Network/virtualNetworks        "vnet-${SUFFIX}"

echo
if (( remaining > 0 )); then
  echo "${remaining} check(s) found remaining project resources."; exit 1
fi
echo "No resources from ${RG} remain. Charges for them stop from deletion onward;"
echo "usage already incurred will still appear in Cost Management (data can lag 24-48 hours or more)."
