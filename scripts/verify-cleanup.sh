#!/usr/bin/env bash
# Read-only check that THIS project's resources are gone after 'terraform destroy'.
# It only queries the project's own resource group and exact resource names, so
# other Project Atlas resources in the subscription are never listed or touched.
#
# A resource counts as absent only when Azure answers "not found". Any other
# error (authentication, permission, network, unexpected) makes the check
# INCONCLUSIVE - it is never treated as proof that a resource is gone.
#
# Usage: ./scripts/verify-cleanup.sh [name-suffix]
#   name-suffix defaults to atlas-foundation-dev (project_name-environment).
#
# Exit codes:
#   0  every check confirmed absence
#   1  at least one project resource (or Terraform state entry) remains
#   2  no remaining resources found, but at least one check was inconclusive
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

SUFFIX="${1:-atlas-foundation-dev}"
RG="rg-${SUFFIX}"
remaining=0
inconclusive=0
ERR_FILE="$(mktemp)"
trap 'rm -f "${ERR_FILE}"' EXIT

# classify_error <stderr-text>: prints authentication|permission|network|unexpected
classify_error() {
  local text="$1"
  if grep -qiE "az login|AADSTS|InvalidAuthenticationToken|ExpiredAuthenticationToken|refresh token|no subscriptions found|Please run 'az|not logged in|AuthenticationFailed" <<<"${text}"; then
    echo authentication
  elif grep -qiE "AuthorizationFailed|does not have authorization|Forbidden|LinkedAuthorizationFailed|RequestDisallowedByPolicy" <<<"${text}"; then
    echo permission
  elif grep -qiE "ConnectionError|Max retries exceeded|Failed to establish a new connection|Name or service not known|NameResolutionError|Temporary failure in name resolution|timed out|Connection refused|Connection reset|Network is unreachable|SSLError|ProxyError" <<<"${text}"; then
    echo network
  else
    echo unexpected
  fi
}

indent() { while IFS= read -r line; do printf '    %s\n' "${line}"; done; }

is_not_found() {
  grep -qE "ResourceNotFound|ResourceGroupNotFound" <<<"$1"
}

report_inconclusive() {
  local what="$1" err="$2" category
  category="$(classify_error "${err}")"
  echo "INCONCLUSIVE (${category} error): ${what}"
  head -n 5 <<<"${err}" | indent
  inconclusive=$((inconclusive + 1))
}

echo "Project resource group: ${RG}"

echo; echo "==> Terraform state (run from this repository)"
if state_out="$(terraform state list 2>"${ERR_FILE}")"; then
  if [[ -n "${state_out}" ]]; then
    echo "FAIL: Terraform state still tracks resources:"
    indent <<<"${state_out}"
    remaining=$((remaining + 1))
  else
    echo "PASS: Terraform state tracks no resources"
  fi
else
  err="$(sed 's/\x1b\[[0-9;]*m//g' "${ERR_FILE}")"
  if grep -q "No state file was found" <<<"${err}"; then
    echo "INCONCLUSIVE: no Terraform state file in $(pwd)."
    echo "    Run this script from the folder where you ran 'terraform apply'."
    inconclusive=$((inconclusive + 1))
  else
    report_inconclusive "'terraform state list' failed; state cannot be treated as empty" "${err}"
  fi
fi

echo; echo "==> Azure CLI session"
azure_ok=true
if account="$(az account show --query name --output tsv 2>"${ERR_FILE}")"; then
  echo "Subscription: ${account}"
else
  report_inconclusive "'az account show' failed; Azure checks below cannot run" "$(cat "${ERR_FILE}")"
  azure_ok=false
fi

echo; echo "==> Resource group"
if [[ "${azure_ok}" == true ]]; then
  if exists="$(az group exists --name "${RG}" 2>"${ERR_FILE}")"; then
    case "${exists}" in
      false) echo "PASS: ${RG} does not exist" ;;
      true)
        echo "FAIL: ${RG} still exists"
        remaining=$((remaining + 1))
        if listing="$(az resource list --resource-group "${RG}" --query "[].{name:name, type:type}" --output table 2>"${ERR_FILE}")"; then
          echo "    Resources inside it:"; indent <<<"${listing}"
        else
          report_inconclusive "could not list resources in ${RG}" "$(cat "${ERR_FILE}")"
        fi
        ;;
      *) report_inconclusive "'az group exists' returned unexpected output" "${exists}" ;;
    esac
  else
    report_inconclusive "'az group exists --name ${RG}' failed" "$(cat "${ERR_FILE}")"
  fi
else
  echo "SKIPPED (counted as inconclusive above): Azure CLI session unavailable"
fi

echo; echo "==> Exact project resource names"
check_absent() {
  local type="$1" name="$2" err
  if az resource show --resource-group "${RG}" --resource-type "${type}" --name "${name}" >/dev/null 2>"${ERR_FILE}"; then
    echo "FAIL: ${type}/${name} still exists"
    remaining=$((remaining + 1))
    return
  fi
  err="$(cat "${ERR_FILE}")"
  if is_not_found "${err}"; then
    echo "PASS: ${type}/${name} not found"
  else
    report_inconclusive "${type}/${name} lookup failed" "${err}"
  fi
}
if [[ "${azure_ok}" == true ]]; then
  check_absent Microsoft.Compute/virtualMachines        "vm-${SUFFIX}"
  check_absent Microsoft.Compute/disks                  "osdisk-${SUFFIX}"
  check_absent Microsoft.Network/networkInterfaces      "nic-${SUFFIX}"
  check_absent Microsoft.Network/publicIPAddresses      "pip-${SUFFIX}"
  check_absent Microsoft.Network/networkSecurityGroups  "nsg-${SUFFIX}"
  check_absent Microsoft.Network/virtualNetworks        "vnet-${SUFFIX}"
else
  echo "SKIPPED (counted as inconclusive above): Azure CLI session unavailable"
fi

echo
echo "Remaining: ${remaining}  Inconclusive: ${inconclusive}"
if (( remaining > 0 )); then
  echo "RESULT: FAIL - project resources remain (see FAIL lines above)."
  exit 1
fi
if (( inconclusive > 0 )); then
  echo "RESULT: INCONCLUSIVE - cleanup is NOT confirmed. Fix the errors above"
  echo "(for example 'az login', permissions or network) and run this script again."
  exit 2
fi
echo "RESULT: PASS - no resources from ${RG} remain. Charges for them stop from deletion"
echo "onward; usage already incurred will still appear in Cost Management (data can lag"
echo "24-48 hours or more). Other resources in the subscription were not queried or changed."
