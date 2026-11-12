#!/usr/bin/env bash
# Reproducible tests for scripts/verify-cleanup.sh and scripts/connectivity-check.sh.
# Uses stub az / terraform / curl / ssh / timeout commands from tests/scripts/stubs,
# placed first on PATH. Nothing contacts Azure or any network host.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="${ROOT}/tests/scripts/stubs"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export STUB_LOG="${WORK}/calls.log"
FAKE_KEY="${WORK}/fake_key"
: >"${FAKE_KEY}"

cases=0
case_failures=0
current_ok=true
OUT="" RC=0 NAME=""

# run_case <name> <expected exit> <script> [VAR=value ...] [-- script args]
run_case() {
  NAME="$1" expected="$2" script="$3"; shift 3
  local vars=() args=()
  while (( $# )); do
    if [[ "$1" == "--" ]]; then shift; args=("$@"); break; fi
    vars+=("$1"); shift
  done
  : >"${STUB_LOG}"
  cases=$((cases + 1))
  current_ok=true
  OUT="$(env PATH="${STUBS}:${PATH}" SSH_KEY="${FAKE_KEY}" CONNECT_TIMEOUT=1 HTTP_TIMEOUT=1 \
           ${vars[@]+"${vars[@]}"} "${ROOT}/scripts/${script}" ${args[@]+"${args[@]}"} 2>&1)"
  RC=$?
  if [[ "${RC}" != "${expected}" ]]; then
    note "expected exit ${expected}, got ${RC}"
  fi
}
note() { current_ok=false; echo "    - $1"; }
has()   { grep -qE -- "$1" <<<"${OUT}" || note "output missing /$1/"; }
lacks() { if grep -qE -- "$1" <<<"${OUT}"; then note "output unexpectedly matches /$1/"; fi; }
count() { local n; n="$(grep -cE -- "$1" <<<"${OUT}" || true)"; [[ "${n}" == "$2" ]] || note "expected $2 lines matching /$1/, got ${n}"; }
az_scoped() {
  local rg="${1:-rg-atlas-foundation-dev}" bad
  bad="$(grep '^az ' "${STUB_LOG}" | grep -v '^az account show' | grep -v -- "${rg}" || true)"
  [[ -z "${bad}" ]] || note "az call not scoped to ${rg}: ${bad}"
}
done_case() {
  if [[ "${current_ok}" == true ]]; then
    echo "PASS: ${NAME}"
  else
    echo "FAIL: ${NAME}"; while IFS= read -r line; do printf '      | %s\n' "${line}"; done <<<"${OUT}"
    case_failures=$((case_failures + 1))
  fi
}

echo "== verify-cleanup.sh =="

run_case "cleanup: all resources absent -> exit 0" 0 verify-cleanup.sh AZ_SCENARIO=clean TF_STATE=empty
count '^PASS: ' 8; lacks 'FAIL|INCONCLUSIVE'; has 'RESULT: PASS'; az_scoped; done_case

run_case "cleanup: custom suffix stays scoped to its own resource group" 0 verify-cleanup.sh AZ_SCENARIO=clean -- atlas-foundation-test
has 'rg-atlas-foundation-test'; has 'vm-atlas-foundation-test not found'; az_scoped rg-atlas-foundation-test; done_case

run_case "cleanup: remaining resource group, public IP and state -> exit 1" 1 verify-cleanup.sh AZ_SCENARIO=remaining TF_STATE=resources
has 'FAIL: Terraform state still tracks'; has 'FAIL: rg-atlas-foundation-dev still exists'
has 'FAIL: Microsoft.Network/publicIPAddresses/pip-atlas-foundation-dev still exists'
has 'PASS: Microsoft.Compute/virtualMachines/vm-atlas-foundation-dev not found'
has 'RESULT: FAIL'; lacks 'RESULT: PASS'; az_scoped; done_case

run_case "cleanup: not logged in (az account show fails) -> exit 2, authentication" 2 verify-cleanup.sh AZ_SCENARIO=auth
has 'INCONCLUSIVE \(authentication error\)'; lacks 'not found'; lacks 'does not exist'
has 'RESULT: INCONCLUSIVE'; lacks 'RESULT: PASS'; done_case

run_case "cleanup: expired token on queries -> exit 2, authentication" 2 verify-cleanup.sh AZ_SCENARIO=auth-expired
count 'INCONCLUSIVE \(authentication error\)' 7; lacks '^PASS: (rg-|Microsoft)'; has 'RESULT: INCONCLUSIVE'; done_case

run_case "cleanup: AuthorizationFailed -> exit 2, permission" 2 verify-cleanup.sh AZ_SCENARIO=permission
count 'INCONCLUSIVE \(permission error\)' 7; lacks '^PASS: (rg-|Microsoft)'; has 'RESULT: INCONCLUSIVE'; az_scoped; done_case

run_case "cleanup: network failure -> exit 2, network" 2 verify-cleanup.sh AZ_SCENARIO=network
count 'INCONCLUSIVE \(network error\)' 7; lacks '^PASS: (rg-|Microsoft)'; has 'RESULT: INCONCLUSIVE'; done_case

run_case "cleanup: unexpected Azure error -> exit 2, unexpected" 2 verify-cleanup.sh AZ_SCENARIO=unexpected
count 'INCONCLUSIVE \(unexpected error\)' 7; lacks '^PASS: (rg-|Microsoft)'; done_case

run_case "cleanup: unexpected 'az group exists' output -> exit 2" 2 verify-cleanup.sh AZ_SCENARIO=garbage
has "INCONCLUSIVE .*unexpected output"; lacks 'PASS: rg-'; done_case

run_case "cleanup: one lookup hits a network error -> exit 2, others still PASS" 2 verify-cleanup.sh AZ_SCENARIO=partial-network
count '^PASS: Microsoft' 5; has 'INCONCLUSIVE \(network error\): Microsoft.Network/networkInterfaces'; done_case

run_case "cleanup: failed 'terraform state list' is not an empty state -> exit 2" 2 verify-cleanup.sh TF_STATE=error
has 'INCONCLUSIVE .*terraform state list'; lacks 'PASS: Terraform state'; has 'RESULT: INCONCLUSIVE'; done_case

run_case "cleanup: no state file in this folder -> exit 2" 2 verify-cleanup.sh TF_STATE=nofile
has 'INCONCLUSIVE: no Terraform state file'; lacks 'PASS: Terraform state'; done_case

run_case "cleanup: remaining resources take precedence over inconclusive -> exit 1" 1 verify-cleanup.sh AZ_SCENARIO=remaining TF_STATE=error
has 'INCONCLUSIVE'; has 'RESULT: FAIL'; done_case

echo; echo "== connectivity-check.sh =="

run_case "connectivity: everything healthy -> exit 0" 0 connectivity-check.sh
count '^PASS: ' 14; lacks '^FAIL'; has 'RESULT: PASS'; done_case

run_case "connectivity: /health returns HTTP 500 -> exit 1" 1 connectivity-check.sh CURL_SCENARIO=health-500
has 'FAIL: GET /health returned HTTP 500'; has 'FAIL: GET /health body'; has 'RESULT: FAIL'; done_case

run_case "connectivity: /health 200 but wrong body -> exit 1" 1 connectivity-check.sh CURL_SCENARIO=health-badbody
has 'PASS: GET /health returned HTTP 200'; has 'FAIL: GET /health body does not contain'; done_case

run_case "connectivity: landing page missing title -> exit 1" 1 connectivity-check.sh CURL_SCENARIO=root-badbody
has "FAIL: GET / body does not contain 'Atlas Platform Foundation'"; done_case

run_case "connectivity: HTTP timeout -> exit 1" 1 connectivity-check.sh CURL_SCENARIO=timeout
has 'FAIL: GET /health: request failed \(curl exit 28'; lacks 'PASS: GET'; done_case

run_case "connectivity: HTTP connection refused -> exit 1" 1 connectivity-check.sh CURL_SCENARIO=refused TCP_SCENARIO=closed
has 'FAIL: TCP 80 not reachable'; has 'curl exit 7'; done_case

run_case "connectivity: SSH timeout never counts as password auth disabled -> exit 1" 1 connectivity-check.sh SSH_SCENARIO=timeout
has 'FAIL: key-authenticated SSH session failed \(ssh exit 255'
has 'FAIL: cloud-init status not verified'; has 'FAIL: container health not verified'
has "FAIL: effective sshd config 'passwordauthentication no' not verified"
has 'FAIL: inconclusive - server did not answer'; lacks 'PASS: .*(password|sshd|publickey|cloud-init|container)'
has 'RESULT: FAIL'; done_case

run_case "connectivity: probe timeout with working key session -> exit 1" 1 connectivity-check.sh SSH_SCENARIO=probe-timeout
has 'PASS: effective sshd config: passwordauthentication no'; has 'FAIL: inconclusive - server did not answer'; done_case

run_case "connectivity: key rejected -> exit 1" 1 connectivity-check.sh SSH_SCENARIO=key-denied
has 'FAIL: key-authenticated SSH session failed'; lacks 'PASS: effective sshd'; done_case

run_case "connectivity: password authentication enabled -> exit 1" 1 connectivity-check.sh SSH_SCENARIO=password-enabled
has "FAIL: effective sshd config: expected 'passwordauthentication no', got 'passwordauthentication yes'"
has 'FAIL: server offers other authentication methods: Permission denied \(publickey,password\)'; done_case

run_case "connectivity: sshd -T unreadable (sudo fails) -> exit 1" 1 connectivity-check.sh SSH_SCENARIO=sshd-unreadable
count "FAIL: effective sshd config not readable" 4; done_case

run_case "connectivity: cloud-init error -> exit 1" 1 connectivity-check.sh SSH_SCENARIO=cloud-init-error
has 'FAIL: cloud-init not finished cleanly'; done_case

run_case "connectivity: container unhealthy -> exit 1" 1 connectivity-check.sh SSH_SCENARIO=unhealthy
has "FAIL: container atlas-web health is 'unhealthy'"; done_case

run_case "connectivity: TCP ports closed -> exit 1" 1 connectivity-check.sh TCP_SCENARIO=closed
count 'FAIL: TCP (22|80) not reachable' 2; done_case

run_case "connectivity: Terraform outputs missing -> exit 2" 2 connectivity-check.sh TF_OUTPUT=fail
has 'ERROR: could not read a valid'; lacks 'PASS'; done_case

run_case "connectivity: SSH key missing -> exit 2" 2 connectivity-check.sh SSH_KEY="${WORK}/missing_key"
has 'ERROR: SSH private key not found'; done_case

echo
echo "Script tests: $((cases - case_failures)) passed, ${case_failures} failed (of ${cases})"
exit $(( case_failures > 0 ? 1 : 0 ))
