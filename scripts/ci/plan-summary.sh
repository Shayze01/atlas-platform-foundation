#!/usr/bin/env bash
# Prints a SANITISED summary of a saved Terraform plan: action counts, resource
# addresses, allowlisted deployment details and fail-closed policy checks
# (scripts/ci/plan_policy.py). IPs, keys, IDs, custom_data, raw plans and state are
# never printed. Writes plan_sha256 and has_changes to $GITHUB_OUTPUT ONLY when every
# policy check passes; otherwise exits 1 so the plan is never offered for approval.
# Usage: scripts/ci/plan-summary.sh <plan-file>
set -uo pipefail
PLAN="${1:-}"
[[ -f "${PLAN}" ]] || { echo "ERROR: plan file '${PLAN}' not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
JSON="$(mktemp)"; POLICY="$(mktemp)"; trap 'rm -f "${JSON}" "${POLICY}"' EXIT
terraform show -json "${PLAN}" >"${JSON}" 2>/dev/null || { echo "ERROR: 'terraform show -json' failed"; exit 2; }
jq -e '.resource_changes' "${JSON}" >/dev/null 2>&1 || { echo "ERROR: plan JSON has no resource_changes"; exit 2; }

sha="$(sha256sum "${PLAN}" | cut -d' ' -f1)"
counts="$(jq -r '
  [.resource_changes[] | .change.actions] as $a |
  "add=\([$a[] | select(. == ["create"])] | length) change=\([$a[] | select(. == ["update"])] | length) destroy=\([$a[] | select(. == ["delete"])] | length) replace=\([$a[] | select(. == ["delete","create"] or . == ["create","delete"])] | length)"' "${JSON}")"
changes="$(jq -r '.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | "\(.change.actions | join("+"))\t\(.address)"' "${JSON}" | sort -k2)"
has_changes=false; [[ -n "${changes}" ]] && has_changes=true

{
  echo "### Terraform plan (sanitised: addresses and actions only)"
  echo
  echo "- Counts: \`${counts}\`"
  echo "- Plan SHA-256: \`${sha}\`"
  echo
  if [[ "${has_changes}" == true ]]; then
    echo "| Action | Resource address |"
    echo "| --- | --- |"
    while IFS=$'\t' read -r act addr; do echo "| ${act} | \`${addr}\` |"; done <<<"${changes}"
  else
    echo "No changes."
  fi
}
python3 "${HERE}/plan_policy.py" <"${JSON}" >"${POLICY}" 2>&1
policy_rc=$?
echo
"${HERE}/sanitize.sh" <"${POLICY}"
if (( policy_rc != 0 )); then
  echo "ERROR: deployment policy failed or could not be evaluated (exit ${policy_rc}); no plan outputs written."
  exit 1
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "plan_sha256=${sha}"; echo "has_changes=${has_changes}"; } >>"${GITHUB_OUTPUT}"
fi
