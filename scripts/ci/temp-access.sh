#!/usr/bin/env bash
# Temporary NSG access for the CI runner: exactly one /32, TCP 22 and 80, removed
# afterwards (the workflow runs 'remove' in an always() step and again in failure cleanup).
#
# Usage: scripts/ci/temp-access.sh add <ip>/32 | remove
# Environment: RG (default rg-atlas-foundation-dev), NSG (default nsg-atlas-foundation-dev)
# 'remove' succeeds only when Azure confirms the rule is absent (NotFound);
# any other error is INCONCLUSIVE (exit 2), never reported as removed.
set -uo pipefail
RG="${RG:-rg-atlas-foundation-dev}"
NSG="${NSG:-nsg-atlas-foundation-dev}"
RULE="Allow-CI-Runner-Temporary"
PRIORITY=130
ERR="$(mktemp)"; trap 'rm -f "${ERR}"' EXIT
octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'

case "${1:-}" in
  add)
    cidr="${2:-}"
    if [[ ! "${cidr}" =~ ^${octet}(\.${octet}){3}/32$ || "${cidr}" == 0.0.0.0/32 ]]; then
      echo "ERROR: refusing temporary access for '${cidr}': exactly one IPv4 /32 is allowed"; exit 2
    fi
    if az network nsg rule create --resource-group "${RG}" --nsg-name "${NSG}" --name "${RULE}" \
         --priority "${PRIORITY}" --direction Inbound --access Allow --protocol Tcp \
         --source-address-prefixes "${cidr}" --source-port-ranges '*' \
         --destination-address-prefixes '*' --destination-port-ranges 22 80 \
         --description "Temporary CI validation access; removed by the same workflow run" \
         --output none 2>"${ERR}"; then
      echo "Temporary rule ${RULE} added (one /32, TCP 22 and 80)"
    else
      echo "ERROR: could not add ${RULE}: $(head -n 1 "${ERR}")"; exit 1
    fi ;;
  remove)
    if az network nsg show --resource-group "${RG}" --name "${NSG}" --output none 2>"${ERR}"; then :
    elif grep -qE "ResourceNotFound|ResourceGroupNotFound" "${ERR}"; then
      echo "NSG ${NSG} does not exist; no temporary rule can remain"; exit 0
    else
      echo "INCONCLUSIVE: cannot read NSG ${NSG}: $(head -n 1 "${ERR}")"; exit 2
    fi
    az network nsg rule delete --resource-group "${RG}" --nsg-name "${NSG}" --name "${RULE}" --output none 2>"${ERR}" || true
    if az network nsg rule show --resource-group "${RG}" --nsg-name "${NSG}" --name "${RULE}" --output none 2>"${ERR}"; then
      echo "FAIL: ${RULE} still exists"; exit 1
    elif grep -qE "NotFound" "${ERR}"; then
      echo "Temporary rule ${RULE} confirmed absent"
    else
      echo "INCONCLUSIVE: cannot confirm ${RULE} is absent: $(head -n 1 "${ERR}")"; exit 2
    fi ;;
  *) echo "Usage: $0 add <ip>/32 | remove"; exit 2 ;;
esac
