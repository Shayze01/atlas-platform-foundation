#!/usr/bin/env bash
# Prints a SANITISED summary of a saved Terraform plan: action counts and resource
# addresses only. Attribute values (IPs, keys, custom_data, IDs) are never printed.
# Also writes plan_sha256 and has_changes to $GITHUB_OUTPUT when set.
# Usage: scripts/ci/plan-summary.sh <plan-file>
set -uo pipefail
PLAN="${1:-}"
[[ -f "${PLAN}" ]] || { echo "ERROR: plan file '${PLAN}' not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found"; exit 2; }
JSON="$(mktemp)"; trap 'rm -f "${JSON}"' EXIT
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
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "plan_sha256=${sha}"; echo "has_changes=${has_changes}"; } >>"${GITHUB_OUTPUT}"
fi
