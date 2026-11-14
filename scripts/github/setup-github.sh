#!/usr/bin/env bash
# OWNER-RUN, one-time GitHub configuration for the Milestone 2 deployment engine.
# Needs the GitHub CLI signed in as the repository owner (admin). Default is a DRY
# RUN that prints every change; --apply makes them.
#
# Configures:
#   - OIDC subject template (repo, context, ref) so Azure trust can require BOTH the
#     environment and refs/heads/main
#   - GITHUB_TOKEN default permission: read-only
#   - environments, each limited to the main branch:
#       azure-plan     no reviewer          (plan identity: Reader)
#       azure-deploy   required reviewer, self-review ALLOWED (solo maintainer)
#       azure-destroy  no reviewer, so cleanup is never blocked waiting for approval
#   - variables: AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, TFSTATE_STORAGE_ACCOUNT,
#     TFSTATE_CONTAINER (repository) and AZURE_CLIENT_ID (per environment)
#   - environment secrets: ADMIN_SOURCE_IP_CIDR, ADMIN_SSH_PUBLIC_KEY, OWNER_TAG
#
# Values come from the environment (bootstrap/bootstrap.sh prints the Azure ones):
#   AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_PLAN_CLIENT_ID AZURE_DEPLOY_CLIENT_ID
#   TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER ADMIN_SOURCE_IP_CIDR ADMIN_SSH_PUBLIC_KEY_FILE OWNER_TAG
# Optional: GITHUB_REPO (default Shayze01/atlas-platform-foundation), REVIEWER (default: repo owner)
#
# Secret values are passed to 'gh secret set' on stdin and never printed.
set -uo pipefail
REPO="${GITHUB_REPO:-Shayze01/atlas-platform-foundation}"
REVIEWER="${REVIEWER:-${REPO%%/*}}"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true
[[ -n "${1:-}" && "${1}" != "--apply" ]] && { echo "Usage: $0 [--apply]"; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: GitHub CLI (gh) not found"; exit 2; }

GUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
bad=0
for v in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_PLAN_CLIENT_ID AZURE_DEPLOY_CLIENT_ID; do
  [[ "${!v:-}" =~ ${GUID} ]] || { echo "ERROR: ${v} must be a lowercase GUID"; bad=1; }
done
[[ "${AZURE_PLAN_CLIENT_ID:-}" != "${AZURE_DEPLOY_CLIENT_ID:-x}" ]] || { echo "ERROR: plan and deploy identities must differ"; bad=1; }
[[ "${TFSTATE_STORAGE_ACCOUNT:-}" =~ ^[a-z0-9]{3,24}$ ]] || { echo "ERROR: TFSTATE_STORAGE_ACCOUNT invalid"; bad=1; }
[[ "${TFSTATE_CONTAINER:-}" =~ ^[a-z0-9-]{3,63}$ ]] || { echo "ERROR: TFSTATE_CONTAINER invalid"; bad=1; }
[[ "${ADMIN_SOURCE_IP_CIDR:-}" =~ ^${octet}(\.${octet}){3}/32$ && "${ADMIN_SOURCE_IP_CIDR}" != 0.0.0.0/32 ]] || { echo "ERROR: ADMIN_SOURCE_IP_CIDR must be a single IPv4 /32"; bad=1; }
if ! { [[ -f "${ADMIN_SSH_PUBLIC_KEY_FILE:-}" ]] && grep -qE '^ssh-(ed25519|rsa) ' "${ADMIN_SSH_PUBLIC_KEY_FILE}" && ! grep -q 'PRIVATE KEY' "${ADMIN_SSH_PUBLIC_KEY_FILE}"; }; then
  echo "ERROR: ADMIN_SSH_PUBLIC_KEY_FILE must be an SSH PUBLIC key file (.pub)"; bad=1
fi
[[ -n "${OWNER_TAG:-}" ]] || { echo "ERROR: OWNER_TAG is required"; bad=1; }
(( bad == 0 )) || exit 2

mode="DRY RUN"; [[ "${APPLY}" == true ]] && mode="APPLY"
echo "GitHub setup for ${REPO} (${mode})"
admin="$(gh api "repos/${REPO}" --jq '.permissions.admin' 2>/dev/null)" || { echo "ERROR: cannot read ${REPO} with gh"; exit 2; }
[[ "${admin}" == true ]] || { echo "ERROR: gh is not signed in as an admin of ${REPO} (sign in as the owner: gh auth login)"; exit 2; }
reviewer_id="$(gh api "users/${REVIEWER}" --jq .id 2>/dev/null)" || { echo "ERROR: cannot look up reviewer ${REVIEWER}"; exit 2; }

# do_gh <description> <stdin-file-or-empty> gh-args...
do_gh() {
  local what="$1" input="$2"; shift 2
  if [[ "${APPLY}" != true ]]; then echo "WOULD RUN (${what}): gh $*"; return 0; fi
  echo "RUN (${what}): gh $*"
  if [[ -n "${input}" ]]; then gh "$@" <"${input}" >/dev/null || { echo "ERROR: ${what} failed"; exit 2; }
  else gh "$@" >/dev/null || { echo "ERROR: ${what} failed"; exit 2; }; fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
json() { local f="${TMP}/$1.json"; cat >"${f}"; printf '%s' "${f}"; }

do_gh "OIDC subject: repo + environment + ref" "$(json oidc <<<'{"use_default":false,"include_claim_keys":["repo","context","ref"],"use_immutable_subject":true}')" \
  api -X PUT "repos/${REPO}/actions/oidc/customization/sub" --input -
do_gh "GITHUB_TOKEN read-only by default" "$(json token <<<'{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}')" \
  api -X PUT "repos/${REPO}/actions/permissions/workflow" --input -

env_body() { # reviewers-json
  printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":%s,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$1"
}
for e in azure-plan azure-deploy azure-destroy; do
  reviewers='[]'; [[ "${e}" == azure-deploy ]] && reviewers="[{\"type\":\"User\",\"id\":${reviewer_id}}]"
  do_gh "environment ${e}" "$(json "env-${e}" <<<"$(env_body "${reviewers}")")" api -X PUT "repos/${REPO}/environments/${e}" --input -
  existing="$(gh api "repos/${REPO}/environments/${e}/deployment-branch-policies" --jq '[.branch_policies[].name] | join(",")' 2>/dev/null || true)"
  if [[ ",${existing}," == *",main,"* ]]; then echo "OK: ${e} already limited to main"
  else do_gh "${e}: only the main branch may deploy" "" api -X POST "repos/${REPO}/environments/${e}/deployment-branch-policies" -f name=main -f type=branch
  fi
done

for v in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER; do
  do_gh "repository variable ${v}" "" variable set "${v}" --repo "${REPO}" --body "${!v}"
done
do_gh "azure-plan AZURE_CLIENT_ID (plan identity)" "" variable set AZURE_CLIENT_ID --repo "${REPO}" --env azure-plan --body "${AZURE_PLAN_CLIENT_ID}"
for e in azure-deploy azure-destroy; do
  do_gh "${e} AZURE_CLIENT_ID (deploy identity)" "" variable set AZURE_CLIENT_ID --repo "${REPO}" --env "${e}" --body "${AZURE_DEPLOY_CLIENT_ID}"
done

printf '%s' "${ADMIN_SOURCE_IP_CIDR}" >"${TMP}/s-ip"
tr -d '\r' <"${ADMIN_SSH_PUBLIC_KEY_FILE}" | head -n 1 >"${TMP}/s-key"
printf '%s' "${OWNER_TAG}" >"${TMP}/s-owner"
for e in azure-plan azure-deploy azure-destroy; do
  do_gh "${e} secret ADMIN_SOURCE_IP_CIDR (value not shown)" "${TMP}/s-ip" secret set ADMIN_SOURCE_IP_CIDR --repo "${REPO}" --env "${e}"
  do_gh "${e} secret ADMIN_SSH_PUBLIC_KEY (value not shown)" "${TMP}/s-key" secret set ADMIN_SSH_PUBLIC_KEY --repo "${REPO}" --env "${e}"
  do_gh "${e} secret OWNER_TAG (value not shown)" "${TMP}/s-owner" secret set OWNER_TAG --repo "${REPO}" --env "${e}"
done
echo
if [[ "${APPLY}" == true ]]; then echo "RESULT: GitHub configured."; else echo "RESULT: dry run - nothing was changed. Re-run with --apply."; fi
