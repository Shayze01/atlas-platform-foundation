#!/usr/bin/env bash
# One-time, OWNER-RUN Azure setup for the Milestone 2 deployment engine.
#
# Creates only these persistent resources (nothing else is created or changed):
#   rg-atlas-tfstate                   Terraform state + deployment identities
#     st<hash>                         Storage account (Entra-only, no shared keys)
#       tfstate (container)            remote state + reviewed plans (plans/)
#     id-atlas-gha-plan                managed identity used by the plan job
#     id-atlas-gha-deploy              managed identity used by apply/validate/destroy
#   rg-atlas-foundation-dev            EMPTY workload resource group (Terraform fills it)
#   role assignments                   see "Permissions" below; no Owner, no role-assignment rights
#
# Default is a DRY RUN: read-only checks, then every change printed as
# "WOULD RUN". Nothing changes unless --apply is given.
#
# Usage:
#   bootstrap/bootstrap.sh --tenant <tenant-id> --subscription <subscription-id> \
#     --owner-tag <name> [--github-repo Shayze01/atlas-platform-foundation] [--location eastus] [--apply]
#
# Run as yourself (Owner or User Access Administrator + Contributor on the subscription),
# for example in Azure Cloud Shell. It never deletes anything and never touches
# NetworkWatcherRG or any other resource group.
#
# Exit codes: 0 success (or clean dry run), 1 a safety check failed, 2 usage or Azure CLI error.
set -uo pipefail

STATE_RG="rg-atlas-tfstate"
WORKLOAD_RG="rg-atlas-foundation-dev"
CONTAINER="tfstate"
PLAN_ID="id-atlas-gha-plan"
DEPLOY_ID="id-atlas-gha-deploy"
LOCK_NAME="lock-atlas-tfstate-nodelete"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
OIDC_AUDIENCE="api://AzureADTokenExchange"
ALLOWED_RGS=("${STATE_RG}" "${WORKLOAD_RG}")

TENANT="" SUBSCRIPTION="" OWNER_TAG="" REPO="Shayze01/atlas-platform-foundation" LOCATION="eastus" APPLY=false
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while (( $# )); do
  case "$1" in
    --tenant) TENANT="${2:-}"; shift 2 ;;
    --subscription) SUBSCRIPTION="${2:-}"; shift 2 ;;
    --owner-tag) OWNER_TAG="${2:-}"; shift 2 ;;
    --github-repo) REPO="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown argument '$1'"; exit 2 ;;
  esac
done

GUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "${TENANT}" =~ ${GUID} ]] || { echo "ERROR: --tenant must be a lowercase GUID"; exit 2; }
[[ "${SUBSCRIPTION}" =~ ${GUID} ]] || { echo "ERROR: --subscription must be a lowercase GUID"; exit 2; }
[[ "${REPO}" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || { echo "ERROR: --github-repo must be owner/name"; exit 2; }
[[ "${LOCATION}" =~ ^[a-z0-9]+$ ]] || { echo "ERROR: --location must be an Azure region name such as eastus"; exit 2; }
[[ "${OWNER_TAG}" =~ ^[A-Za-z0-9@._\ -]{1,64}$ ]] || { echo "ERROR: --owner-tag is required (letters, digits, space, @ . _ -)"; exit 2; }
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found"; exit 2; }

# Globally unique, stable storage account name derived from the subscription ID.
SA="statlas$(printf '%s' "${SUBSCRIPTION}" | sha256sum | cut -c1-11)"
RG_SCOPE() { printf '/subscriptions/%s/resourceGroups/%s' "${SUBSCRIPTION}" "$1"; }
SA_ID="$(RG_SCOPE "${STATE_RG}")/providers/Microsoft.Storage/storageAccounts/${SA}"
CONTAINER_SCOPE="${SA_ID}/blobServices/default/containers/${CONTAINER}"

ERR="$(mktemp)"; POLICY="$(mktemp)"
trap 'rm -f "${ERR}" "${POLICY}"' EXIT
changes=0
mode="DRY RUN"; [[ "${APPLY}" == true ]] && mode="APPLY"
echo "Atlas Milestone 2 bootstrap (${mode})"

# run <description> -- az ...   : prints the change; executes it only with --apply.
run() {
  local what="$1"; shift; [[ "$1" == "--" ]] && shift
  changes=$((changes + 1))
  if [[ "${APPLY}" != true ]]; then
    echo "WOULD RUN (${what}): az $*"
    return 0
  fi
  echo "RUN (${what}): az $*"
  if ! az "$@" >/dev/null 2>"${ERR}"; then
    echo "ERROR: '${what}' failed:"; head -n 5 "${ERR}" | sed 's/^/    /'
    echo "Stopped. Nothing is rolled back automatically; the script is safe to re-run."
    exit 2
  fi
}
guard_rg() { # refuse any write outside the two allowed resource groups
  local rg="$1" ok
  for ok in "${ALLOWED_RGS[@]}"; do [[ "${rg}" == "${ok}" ]] && return 0; done
  echo "SAFETY: refusing to touch resource group '${rg}' (allowed: ${ALLOWED_RGS[*]})"; exit 1
}

echo; echo "==> 1. Tenant and subscription"
if ! acct="$(az account show --query '[tenantId, id]' --output tsv 2>"${ERR}")"; then
  echo "ERROR: 'az account show' failed (sign in with 'az login'):"; head -n 3 "${ERR}" | sed 's/^/    /'; exit 2
fi
read -r cur_tenant cur_sub <<<"$(tr '\n' ' ' <<<"${acct}")"
if [[ "${cur_tenant}" != "${TENANT}" || "${cur_sub}" != "${SUBSCRIPTION}" ]]; then
  echo "SAFETY: signed-in tenant/subscription (${cur_tenant:-?} / ${cur_sub:-?}) do not match --tenant/--subscription."
  echo "        Run 'az account set --subscription ${SUBSCRIPTION}' or fix the arguments. Nothing was changed."
  exit 1
fi
echo "OK: tenant ${TENANT}, subscription ${SUBSCRIPTION}"

echo; echo "==> 2. Existing resources (read-only)"
# expected_only <rg> <allowed-name-regex>: the group must be absent, or contain only expected resources.
expected_only() {
  local rg="$1" allowed="$2" exists names unexpected
  guard_rg "${rg}"
  if ! exists="$(az group exists --name "${rg}" 2>"${ERR}")"; then
    echo "ERROR: could not check ${rg}:"; head -n 3 "${ERR}" | sed 's/^/    /'; exit 2
  fi
  case "${exists}" in
    false) echo "OK: ${rg} does not exist yet (will be created)"; return 0 ;;
    true) ;;
    *) echo "ERROR: unexpected 'az group exists' output for ${rg}: ${exists}"; exit 2 ;;
  esac
  if ! names="$(az resource list --resource-group "${rg}" --query '[].name' --output tsv 2>"${ERR}")"; then
    echo "ERROR: could not list ${rg}:"; head -n 3 "${ERR}" | sed 's/^/    /'; exit 2
  fi
  unexpected="$(grep -vE "^(${allowed})$" <<<"${names}" | grep -v '^$' || true)"
  if [[ -n "${unexpected}" ]]; then
    echo "SAFETY: ${rg} already contains resources this script did not create:"
    while IFS= read -r line; do echo "    ${line}"; done <<<"${unexpected}"
    echo "        Remove them (for a leftover workload: run the Destroy workflow) and re-run. Nothing was changed."
    exit 1
  fi
  echo "OK: ${rg} exists and contains only expected resources (${names:-none}); will be updated in place"
}
expected_only "${STATE_RG}" "${SA}|${PLAN_ID}|${DEPLOY_ID}"
expected_only "${WORKLOAD_RG}" "__no_resources_expected__"

echo; echo "==> 3. State backend (persistent)"
guard_rg "${STATE_RG}"
run "state resource group" -- group create --name "${STATE_RG}" --location "${LOCATION}" \
  --tags Project=atlas-platform Purpose=terraform-state Lifecycle=persistent "Owner=${OWNER_TAG}"
run "storage account (Entra-only)" -- storage account create --name "${SA}" --resource-group "${STATE_RG}" \
  --location "${LOCATION}" --sku Standard_LRS --kind StorageV2 --access-tier Hot \
  --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false \
  --allow-shared-key-access false --allow-cross-tenant-replication false \
  --tags Project=atlas-platform Purpose=terraform-state Lifecycle=persistent "Owner=${OWNER_TAG}"
run "versioning + soft delete" -- storage account blob-service-properties update --account-name "${SA}" \
  --resource-group "${STATE_RG}" --enable-versioning true --enable-delete-retention true \
  --delete-retention-days 14 --enable-container-delete-retention true --container-delete-retention-days 14
run "private state container" -- storage container-rm create --storage-account "${SA}" \
  --resource-group "${STATE_RG}" --name "${CONTAINER}" --public-access off
cat >"${POLICY}" <<JSON
{"rules":[
 {"enabled":true,"name":"expire-reviewed-plans","type":"Lifecycle","definition":{
   "filters":{"blobTypes":["blockBlob"],"prefixMatch":["${CONTAINER}/plans/"]},
   "actions":{"baseBlob":{"delete":{"daysAfterModificationGreaterThan":7}},
              "version":{"delete":{"daysAfterCreationGreaterThan":7}}}}},
 {"enabled":true,"name":"expire-old-state-versions","type":"Lifecycle","definition":{
   "filters":{"blobTypes":["blockBlob"],"prefixMatch":["${CONTAINER}/atlas-platform-foundation/"]},
   "actions":{"version":{"delete":{"daysAfterCreationGreaterThan":30}}}}}
]}
JSON
run "lifecycle: delete plans after 7 days, old state versions after 30" -- storage account management-policy create \
  --account-name "${SA}" --resource-group "${STATE_RG}" --policy "@${POLICY}"
run "delete lock on the storage account" -- lock create --name "${LOCK_NAME}" --lock-type CanNotDelete \
  --resource-group "${STATE_RG}" --resource "${SA}" --resource-type Microsoft.Storage/storageAccounts \
  --notes "Atlas Terraform state. Removed only by bootstrap/teardown.sh after workloads are gone."

echo; echo "==> 4. Workload resource group (persistent, empty)"
guard_rg "${WORKLOAD_RG}"
run "workload resource group" -- group create --name "${WORKLOAD_RG}" --location "${LOCATION}" \
  --tags Project=atlas-foundation Environment=dev ManagedBy=bootstrap Lifecycle=persistent "Owner=${OWNER_TAG}"

echo; echo "==> 5. Deployment identities (user-assigned managed identities: no secrets exist)"
principal_of() { # prints principal id, or a placeholder in dry run when the identity does not exist yet
  local id
  if id="$(az identity show --name "$1" --resource-group "${STATE_RG}" --query principalId --output tsv 2>/dev/null)" && [[ -n "${id}" ]]; then
    printf '%s' "${id}"
  elif [[ "${APPLY}" != true ]]; then
    printf '<principal-id-of-%s>' "$1"
  else
    echo "ERROR: identity $1 not found after creation" >&2; exit 2
  fi
}
client_of() {
  az identity show --name "$1" --resource-group "${STATE_RG}" --query clientId --output tsv 2>/dev/null || printf '<client-id-of-%s>' "$1"
}
for id in "${PLAN_ID}" "${DEPLOY_ID}"; do
  run "identity ${id}" -- identity create --name "${id}" --resource-group "${STATE_RG}" --location "${LOCATION}" \
    --tags Project=atlas-platform Purpose=github-actions-oidc Lifecycle=persistent "Owner=${OWNER_TAG}"
done

echo; echo "==> 6. Federated credentials (GitHub OIDC; exact subject, no wildcards)"
# Subjects use the repository's customised OIDC claim template (repo, context, ref),
# set by scripts/github/setup-github.sh: a token is only accepted for the named
# environment AND refs/heads/main. Any other branch, PR, fork or environment is rejected.
subject() { printf 'repo:%s:environment:%s:ref:refs/heads/main' "${REPO}" "$1"; }
fed() { # identity credential-name environment
  run "federated credential $2" -- identity federated-credential create --name "$2" \
    --identity-name "$1" --resource-group "${STATE_RG}" --issuer "${OIDC_ISSUER}" \
    --subject "$(subject "$3")" --audiences "${OIDC_AUDIENCE}"
}
fed "${PLAN_ID}" gha-azure-plan-main azure-plan
fed "${DEPLOY_ID}" gha-azure-deploy-main azure-deploy
fed "${DEPLOY_ID}" gha-azure-destroy-main azure-destroy

echo; echo "==> 7. Role assignments (least privilege; none can assign roles)"
assign() { # identity role scope
  local principal; principal="$(principal_of "$1")" || exit 2
  if [[ "${APPLY}" == true ]] && [[ -n "$(az role assignment list --assignee "${principal}" --role "$2" --scope "$3" --query '[].id' --output tsv 2>/dev/null)" ]]; then
    echo "OK: $1 already has '$2' on $3"; return 0
  fi
  run "$1: $2" -- role assignment create --assignee-object-id "${principal}" \
    --assignee-principal-type ServicePrincipal --role "$2" --scope "$3"
}
assign "${PLAN_ID}"   "Reader"                        "$(RG_SCOPE "${WORKLOAD_RG}")"
assign "${PLAN_ID}"   "Storage Blob Data Contributor" "${CONTAINER_SCOPE}"
assign "${DEPLOY_ID}" "Contributor"                   "$(RG_SCOPE "${WORKLOAD_RG}")"
assign "${DEPLOY_ID}" "Storage Blob Data Contributor" "${CONTAINER_SCOPE}"

echo; echo "==> 8. GitHub configuration values (identifiers, not credentials)"
cat <<OUT
AZURE_TENANT_ID=${TENANT}
AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION}
AZURE_PLAN_CLIENT_ID=$(client_of "${PLAN_ID}")
AZURE_DEPLOY_CLIENT_ID=$(client_of "${DEPLOY_ID}")
TFSTATE_STORAGE_ACCOUNT=${SA}
TFSTATE_CONTAINER=${CONTAINER}
OUT
echo "Pass these to scripts/github/setup-github.sh (see docs/milestone-2.md)."
echo
if [[ "${APPLY}" == true ]]; then
  echo "RESULT: applied ${changes} change(s). Re-running is safe (idempotent)."
else
  echo "RESULT: dry run - ${changes} change(s) listed above, nothing was changed. Re-run with --apply."
fi
