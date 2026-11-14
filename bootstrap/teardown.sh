#!/usr/bin/env bash
# COMPLETE teardown of the Milestone 2 backend and identities. OWNER-RUN, rarely needed.
#
# This is NOT routine cleanup. Routine cleanup is the Destroy workflow, which removes
# the workload (VM, network, IP, disk) and keeps everything below so the next
# deployment works. Run this only when retiring the deployment engine.
#
# Order (the state backend is deleted LAST):
#   1. confirm tenant/subscription
#   2. confirm the workload is gone: rg-atlas-foundation-dev absent or EMPTY, and the
#      Terraform state blob lists no resources (any error stops the teardown)
#   3. delete rg-atlas-foundation-dev (empty) - its role assignments go with it
#   4. delete role assignments on the state container, then both managed identities
#      (their federated credentials go with them)
#   5. remove the storage account delete lock, then delete rg-atlas-tfstate
#
# Default is a DRY RUN. Use --apply to delete. Never touches NetworkWatcherRG or any
# other resource group.
#
# Usage: bootstrap/teardown.sh --tenant <id> --subscription <id> [--apply]
# Exit codes: 0 done (or clean dry run), 1 safety check failed (workload still present), 2 error/inconclusive.
set -uo pipefail

STATE_RG="rg-atlas-tfstate"
WORKLOAD_RG="rg-atlas-foundation-dev"
CONTAINER="tfstate"
STATE_KEY="atlas-platform-foundation/dev.tfstate"
PLAN_ID="id-atlas-gha-plan"
DEPLOY_ID="id-atlas-gha-deploy"
LOCK_NAME="lock-atlas-tfstate-nodelete"

TENANT="" SUBSCRIPTION="" APPLY=false
while (( $# )); do
  case "$1" in
    --tenant) TENANT="${2:-}"; shift 2 ;;
    --subscription) SUBSCRIPTION="${2:-}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "ERROR: unknown argument '$1'"; exit 2 ;;
  esac
done
GUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "${TENANT}" =~ ${GUID} && "${SUBSCRIPTION}" =~ ${GUID} ]] || { echo "ERROR: --tenant and --subscription must be lowercase GUIDs"; exit 2; }
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (needed to validate the Terraform state)"; exit 2; }

SA="statlas$(printf '%s' "${SUBSCRIPTION}" | sha256sum | cut -c1-11)"
CONTAINER_SCOPE="/subscriptions/${SUBSCRIPTION}/resourceGroups/${STATE_RG}/providers/Microsoft.Storage/storageAccounts/${SA}/blobServices/default/containers/${CONTAINER}"
ERR="$(mktemp)"; STATE_FILE="$(mktemp)"
trap 'rm -f "${ERR}" "${STATE_FILE}"' EXIT
mode="DRY RUN"; [[ "${APPLY}" == true ]] && mode="APPLY"
echo "Atlas Milestone 2 COMPLETE teardown (${mode})"
show_err() { head -n 3 "${ERR}" | while IFS= read -r l; do echo "    ${l}"; done; }

run() {
  local what="$1"; shift; [[ "$1" == "--" ]] && shift
  if [[ "${APPLY}" != true ]]; then echo "WOULD RUN (${what}): az $*"; return 0; fi
  echo "RUN (${what}): az $*"
  az "$@" >/dev/null 2>"${ERR}" || { echo "ERROR: '${what}' failed:"; show_err; echo "Stopped; re-run after fixing."; exit 2; }
}

echo; echo "==> 1. Tenant and subscription"
acct="$(az account show --query '[tenantId, id]' --output tsv 2>"${ERR}")" || { echo "ERROR: 'az account show' failed:"; show_err; exit 2; }
read -r cur_tenant cur_sub <<<"$(tr '\n' ' ' <<<"${acct}")"
if [[ "${cur_tenant}" != "${TENANT}" || "${cur_sub}" != "${SUBSCRIPTION}" ]]; then
  echo "SAFETY: signed-in tenant/subscription do not match the arguments. Nothing was changed."; exit 1
fi
echo "OK: tenant ${TENANT}, subscription ${SUBSCRIPTION}"

echo; echo "==> 2. Confirm the workload is gone (any doubt stops here)"
wl_exists="$(az group exists --name "${WORKLOAD_RG}" 2>"${ERR}")" || { echo "INCONCLUSIVE: cannot check ${WORKLOAD_RG}:"; show_err; exit 2; }
case "${wl_exists}" in
  false) echo "OK: ${WORKLOAD_RG} does not exist" ;;
  true)
    n="$(az resource list --resource-group "${WORKLOAD_RG}" --query 'length(@)' --output tsv 2>"${ERR}")" || { echo "INCONCLUSIVE: cannot list ${WORKLOAD_RG}:"; show_err; exit 2; }
    [[ "${n}" =~ ^[0-9]+$ ]] || { echo "INCONCLUSIVE: unexpected resource count '${n}'"; exit 2; }
    if (( n > 0 )); then
      echo "SAFETY: ${WORKLOAD_RG} still contains ${n} resource(s). Run the Destroy workflow first. Nothing was changed."; exit 1
    fi
    echo "OK: ${WORKLOAD_RG} exists and is empty" ;;
  *) echo "INCONCLUSIVE: unexpected 'az group exists' output '${wl_exists}'"; exit 2 ;;
esac
st_exists="$(az group exists --name "${STATE_RG}" 2>"${ERR}")" || { echo "INCONCLUSIVE: cannot check ${STATE_RG}:"; show_err; exit 2; }
case "${st_exists}" in
  true|false) ;;
  *) echo "INCONCLUSIVE: unexpected 'az group exists' output for ${STATE_RG}: '${st_exists}'. Nothing was changed."; exit 2 ;;
esac
# A supported Terraform state: a JSON object with "version": 4 and a "resources" array
# whose entries are objects with a string "mode" of "managed" or "data". Anything else
# ({}, null, missing or wrong-type resources, malformed JSON) is INCONCLUSIVE.
STATE_SHAPE='type == "object" and .version == 4 and (.resources | type == "array")
  and all(.resources[]; type == "object" and (.mode == "managed" or .mode == "data"))'
if [[ "${st_exists}" == true ]]; then
  # Reading the state needs a data-plane role (e.g. Storage Blob Data Reader) for the signed-in owner.
  if az storage blob download --auth-mode login --account-name "${SA}" --container-name "${CONTAINER}" \
       --name "${STATE_KEY}" --file "${STATE_FILE}" --no-progress >/dev/null 2>"${ERR}"; then
    # --slurp: an empty file or several JSON documents become an array that fails the length check.
    if ! jq -e -s "length == 1 and (.[0] | ${STATE_SHAPE})" "${STATE_FILE}" >/dev/null 2>&1; then
      echo "INCONCLUSIVE: the state blob is not a supported Terraform state (expected version 4 with a resources array). Nothing was changed."; exit 2
    fi
    res="$(jq '[.resources[] | select(.mode == "managed")] | length' "${STATE_FILE}" 2>/dev/null)"
    [[ "${res}" =~ ^[0-9]+$ ]] || { echo "INCONCLUSIVE: could not count managed resources in the state. Nothing was changed."; exit 2; }
    if (( res > 0 )); then
      echo "SAFETY: Terraform state still tracks ${res} managed resource(s). Run the Destroy workflow first. Nothing was changed."; exit 1
    fi
    echo "OK: Terraform state tracks no managed resources"
  elif grep -qE "BlobNotFound|ContainerNotFound" "${ERR}"; then
    echo "OK: no Terraform state blob found"
  else
    echo "INCONCLUSIVE: could not read the Terraform state blob (grant yourself 'Storage Blob Data Reader' on the container, then re-run):"; show_err; exit 2
  fi
else
  echo "OK: ${STATE_RG} does not exist"
fi

echo; echo "==> 3. Workload resource group (empty; its role assignments are deleted with it)"
[[ "${wl_exists}" == true ]] && run "delete empty ${WORKLOAD_RG}" -- group delete --name "${WORKLOAD_RG}" --yes
[[ "${wl_exists}" == false ]] && echo "skip: already absent"

echo; echo "==> 4. Identities and their state-container role assignments"
if [[ "${st_exists}" == true ]]; then
  for id in "${PLAN_ID}" "${DEPLOY_ID}"; do
    if pid="$(az identity show --name "${id}" --resource-group "${STATE_RG}" --query principalId --output tsv 2>"${ERR}")"; then
      run "role assignments of ${id} on the state container" -- role assignment delete --assignee "${pid}" --scope "${CONTAINER_SCOPE}"
      run "identity ${id}" -- identity delete --name "${id}" --resource-group "${STATE_RG}"
    elif grep -q "ResourceNotFound" "${ERR}"; then
      echo "skip: ${id} already absent"
    else
      echo "INCONCLUSIVE: cannot read ${id}:"; show_err; exit 2
    fi
  done

  echo; echo "==> 5. State backend (LAST)"
  run "remove delete lock" -- lock delete --name "${LOCK_NAME}" --resource-group "${STATE_RG}" \
    --resource "${SA}" --resource-type Microsoft.Storage/storageAccounts
  run "delete ${STATE_RG} (state, plans, storage account)" -- group delete --name "${STATE_RG}" --yes
else
  echo "skip: ${STATE_RG} already absent"
fi

echo
if [[ "${APPLY}" == true ]]; then
  echo "RESULT: teardown complete. Deleted resources stop accruing charges; billing data can lag 24-48 hours."
  echo "Remove the GitHub environments/variables too if no longer needed (docs/milestone-2.md)."
else
  echo "RESULT: dry run - nothing was changed. Re-run with --apply."
fi
