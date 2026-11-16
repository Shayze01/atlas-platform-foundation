#!/usr/bin/env bash
# Guarded workload cleanup: destroys ONLY when scripts/ci/expiry_decision.py says DESTROY.
#   MODE=sweep            hourly expiry sweep (destroy.yml)
#   MODE=failure-cleanup  deploy.yml failure-cleanup; APPLY_ATTEMPTED (true when this
#                         run started terraform apply), OWN_EXPIRES_AT (this run's plan),
#                         PRE_APPLY_SNAPSHOT (state_snapshot.py JSON taken just before apply)
#                         and APPLY_ERROR (state-lock, stale-plan, state-persist-failed, other)
# Reads Terraform state (terraform show -json; after an apply attempt also `terraform
# state pull` for lineage/serial) and `az resource list` for the workload group only. Never queries, tags or deletes the state backend, identities or the group
# itself; deletion is only `terraform destroy` of the state-managed workload, followed by
# verify-cleanup.sh with KEEP_RESOURCE_GROUP=1.
# Exit: 0 NOOP/PROTECT/destroyed and verified; 1 destroy or verification failed;
#       2 INCONCLUSIVE (read error, lock, or uncertain tags/state): nothing destroyed.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
MODE="${MODE:-}"
RG="${RG:-rg-atlas-foundation-dev}"
VERIFY_CLEANUP="${VERIFY_CLEANUP:-./scripts/verify-cleanup.sh}"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
out() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1" >>"${GITHUB_OUTPUT}"; return 0; }
finish() { # result exit-code
  out "result=$1"; echo "RESULT (${MODE}): $1"; exit "$2"
}

case "${MODE}" in
  sweep|failure-cleanup) ;;
  *) echo "ERROR: MODE must be sweep or failure-cleanup"; exit 2 ;;
esac
if [[ "${MODE}" == failure-cleanup && ! "${APPLY_ATTEMPTED:-}" =~ ^(true|false|)$ ]]; then
  echo "ERROR: APPLY_ATTEMPTED must be true, false or empty"; exit 2
fi

args=(--mode "${MODE}" --state "${WORK}/state.json" --azure "${WORK}/azure.json" --resource-group "${RG}"
      --own-expires-at "${OWN_EXPIRES_AT:-}" --apply-attempted "${APPLY_ATTEMPTED:-}")
[[ -n "${ATLAS_NOW:-}" ]] && args+=(--now "${ATLAS_NOW}")
inconclusive() { echo "INCONCLUSIVE: $1"; out "decision=INCONCLUSIVE"; finish INCONCLUSIVE 2; }

if ! terraform show -json >"${WORK}/state.json" 2>"${WORK}/err"; then
  inconclusive "cannot read Terraform state: $(head -n 1 "${WORK}/err")"
fi
if [[ "${MODE}" == failure-cleanup && "${APPLY_ATTEMPTED:-}" == true ]]; then
  echo "This run attempted terraform apply: ownership is decided from the pre-apply and current state, not assumed."
  printf '%s' "${PRE_APPLY_SNAPSHOT:-}" >"${WORK}/pre.json"
  if ! terraform state pull >"${WORK}/raw.tfstate" 2>"${WORK}/err"; then
    inconclusive "cannot read Terraform state (state pull): $(head -n 1 "${WORK}/err")"
  fi
  if ! python3 scripts/ci/state_snapshot.py "${WORK}/raw.tfstate" >"${WORK}/post.json" 2>"${WORK}/err"; then
    inconclusive "$(head -n 1 "${WORK}/err")"
  fi
  rm -f "${WORK}/raw.tfstate"
  args+=(--pre-snapshot "${WORK}/pre.json" --post-snapshot "${WORK}/post.json" --apply-error "${APPLY_ERROR:-}")
fi
if ! az resource list --resource-group "${RG}" --output json >"${WORK}/azure.json" 2>"${WORK}/err"; then
  inconclusive "cannot list resources in ${RG}: $(head -n 1 "${WORK}/err")"
fi

python3 scripts/ci/expiry_decision.py "${args[@]}" >"${WORK}/decision" 2>&1
rc=$?
cat "${WORK}/decision"
decision="$(sed -n 's/^DECISION=//p' "${WORK}/decision")"
out "decision=${decision:-INCONCLUSIVE}"
if (( rc != 0 )) || [[ -z "${decision}" ]]; then finish INCONCLUSIVE 2; fi
case "${decision}" in
  NOOP|PROTECT) finish "${decision}" 0 ;;
  DESTROY) ;;
  *) finish INCONCLUSIVE 2 ;;
esac

if ! terraform destroy -auto-approve -input=false -lock-timeout=5m -no-color >"${WORK}/destroy" 2>&1; then
  tail -n 20 "${WORK}/destroy"
  if grep -q "Error acquiring the state lock" "${WORK}/destroy"; then
    echo "INCONCLUSIVE: state is locked by another operation; nothing was destroyed by this run"
    finish INCONCLUSIVE 2
  fi
  echo "FAIL: terraform destroy failed"
  finish DESTROY-FAILED 1
fi
grep -E "^Destroy complete" "${WORK}/destroy" || true
KEEP_RESOURCE_GROUP=1 "${VERIFY_CLEANUP}"
vrc=$?
case "${vrc}" in
  0) finish DESTROYED 0 ;;
  1) finish VERIFY-FAILED 1 ;;
  *) finish VERIFY-INCONCLUSIVE 2 ;;
esac
