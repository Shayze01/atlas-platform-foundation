#!/usr/bin/env bash
# Reproducible tests for scripts/verify-cleanup.sh, scripts/connectivity-check.sh and
# scripts/azure-validate.sh.
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
# path_without <tool>: a PATH directory holding the system tools and stubs, minus <tool>.
path_without() {
  local dir="${WORK}/path-without-$1" f
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}"
    for f in /usr/bin/* /bin/*; do [[ -x "${f}" ]] && ln -sf "${f}" "${dir}/" 2>/dev/null; done
    for f in "${STUBS}"/*; do ln -sf "${f}" "${dir}/"; done
    rm -f "${dir:?}/$1"
  fi
  printf '%s' "${dir}"
}
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

echo; echo "== azure-validate.sh =="

PUBKEY="${WORK}/admin.pub"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAhnnlI7ScyqxeIK1AysQ0aqybx6fYKZbROGFSh78TQ atlas-test-only" >"${PUBKEY}"
STUB_KEY_FP="$(ssh-keygen -lf "${PUBKEY}" | awk '{print $2}')"
export STUB_KEY_FP

run_case "azure-validate public: healthy -> exit 0" 0 azure-validate.sh -- public
count '^PASS: ' 5; lacks 'FAIL'; done_case

run_case "azure-validate public: HTTP timeout -> exit 1" 1 azure-validate.sh CURL_SCENARIO=timeout -- public
count 'FAIL: GET /(health)? ?: ?request failed|FAIL: GET / ?.*request failed' 2; done_case

run_case "azure-validate public: SSH timeout is not proof -> exit 1" 1 azure-validate.sh SSH_SCENARIO=timeout -- public
has 'FAIL: inconclusive - no SSH authentication answer'; lacks 'refuses non-key'; done_case

run_case "azure-validate public: password offered -> exit 1" 1 azure-validate.sh SSH_SCENARIO=password-enabled -- public
has 'FAIL: SSH server offers other methods'; done_case

run_case "azure-validate in-vm: healthy, key installed, outbound via public IP -> exit 0" 0 azure-validate.sh ADMIN_PUBKEY_FILE="${PUBKEY}" -- in-vm
count '^PASS: ' 10; lacks 'FAIL'; has 'outbound traffic leaves via'; done_case

run_case "azure-validate in-vm: Run Command error never passes -> exit 1" 1 azure-validate.sh RC_SCENARIO=fail -- in-vm
has 'FAIL: Azure Run Command failed'; lacks 'PASS'; done_case

run_case "azure-validate in-vm: outbound IP mismatch -> exit 1" 1 azure-validate.sh RC_SCENARIO=outbound-mismatch -- in-vm
has 'FAIL: in-VM: outbound'; done_case

run_case "azure-validate in-vm: password auth enabled -> exit 1" 1 azure-validate.sh RC_SCENARIO=password-enabled -- in-vm
has 'FAIL: in-VM: effective sshd: password'; done_case

run_case "azure-validate in-vm: cloud-init still running -> exit 1" 1 azure-validate.sh RC_SCENARIO=cloud-init-running -- in-vm
has 'FAIL: in-VM: cloud-init finished'; done_case

run_case "azure-validate in-vm: container unhealthy -> exit 1" 1 azure-validate.sh RC_SCENARIO=unhealthy -- in-vm
has 'FAIL: in-VM: container atlas-web healthy'; done_case

run_case "azure-validate in-vm: admin key not installed -> exit 1" 1 azure-validate.sh ADMIN_PUBKEY_FILE="${PUBKEY}" RC_SCENARIO=wrong-key -- in-vm
has 'not in authorized_keys'; done_case

run_case "azure-validate blocked: rules final, HTTP/SSH time out -> exit 0" 0 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=timeout TCP_SCENARIO=closed -- blocked
count '^PASS: ' 3; lacks 'FAIL'; done_case

run_case "azure-validate blocked: temporary rule still present -> exit 1" 1 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 NSG_SCENARIO=temp-present CURL_SCENARIO=timeout TCP_SCENARIO=closed -- blocked
has 'FAIL: NSG rules differ'; done_case

run_case "azure-validate blocked: HTTP still reachable -> exit 1" 1 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 TCP_SCENARIO=closed -- blocked
has 'FAIL: HTTP from this machine still connects'; done_case

run_case "azure-validate blocked: NSG read error is inconclusive, not a pass -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 NSG_SCENARIO=error CURL_SCENARIO=timeout TCP_SCENARIO=closed -- blocked
has 'INCONCLUSIVE: could not list NSG rules'; lacks 'PASS: NSG'; done_case

run_case "azure-validate blocked: curl 8 connect-timeout wording counts as dropped -> exit 0" 0 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=timeout-curl8 TCP_SCENARIO=closed -- blocked
count '^PASS: ' 3; lacks 'FAIL|INCONCLUSIVE'; done_case

run_case "azure-validate blocked: TCP 22 still connects -> exit 1" 1 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=timeout TCP_SCENARIO=open -- blocked
has 'FAIL: TCP 22 from this machine still connects'; done_case

run_case "azure-validate blocked: HTTP timeout after connecting is not blocked -> exit 1" 1 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=op-timeout TCP_SCENARIO=closed -- blocked
has 'FAIL: HTTP timed out AFTER connecting'; lacks 'PASS: HTTP'; done_case

run_case "azure-validate blocked: HTTP connection refused is inconclusive -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=refused TCP_SCENARIO=closed -- blocked
has 'INCONCLUSIVE: HTTP connection refused'; lacks 'PASS: HTTP'; done_case

run_case "azure-validate blocked: HTTP network unreachable is inconclusive -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=unreachable TCP_SCENARIO=closed -- blocked
has 'INCONCLUSIVE: HTTP probe could not connect'; lacks 'PASS: HTTP'; done_case

run_case "azure-validate blocked: curl invalid option is inconclusive -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=badopt TCP_SCENARIO=closed -- blocked
has 'INCONCLUSIVE: HTTP probe error \(curl exit 2'; lacks 'PASS: HTTP'; done_case

run_case "azure-validate blocked: TCP 22 refused is inconclusive -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=timeout TCP_SCENARIO=refused -- blocked
has 'INCONCLUSIVE: TCP 22 connection refused'; lacks 'PASS: TCP'; done_case

run_case "azure-validate blocked: TCP 22 network unreachable is inconclusive -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=timeout TCP_SCENARIO=unreachable -- blocked
has 'INCONCLUSIVE: TCP 22 probe could not connect'; lacks 'PASS: TCP'; done_case

run_case "azure-validate blocked: timeout tool error (exit 125) is inconclusive -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_SCENARIO=timeout TCP_SCENARIO=badopt -- blocked
has 'INCONCLUSIVE: TCP 22 probe error \(exit 125'; lacks 'PASS: TCP'; done_case

run_case "azure-validate blocked: failed control request -> probes not evaluated, exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CURL_CONTROL=fail CURL_SCENARIO=timeout TCP_SCENARIO=closed -- blocked
has 'INCONCLUSIVE: control request'; lacks 'PASS: (HTTP|TCP)'
if grep -qE '^curl .*203\.0\.113\.10|^timeout ' "${STUB_LOG}"; then note "VM was probed although the control request failed"; fi; done_case

run_case "azure-validate blocked: failure takes precedence over inconclusive -> exit 1" 1 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 NSG_SCENARIO=temp-present CURL_SCENARIO=refused TCP_SCENARIO=closed -- blocked
has 'FAIL: NSG rules differ'; has 'INCONCLUSIVE: HTTP connection refused'; done_case

run_case "azure-validate blocked: 'timeout' missing from PATH -> exit 2 before any Azure call" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 PATH="$(path_without timeout)" -- blocked
has "ERROR: required tool 'timeout' not found"; lacks '^PASS'
if grep -q '^az ' "${STUB_LOG}"; then note "az was called although a required tool is missing"; fi; done_case

run_case "azure-validate blocked: 'curl' missing from PATH -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 PATH="$(path_without curl)" -- blocked
has "ERROR: required tool 'curl' not found"; lacks '^PASS'; done_case

run_case "azure-validate blocked: malformed EXPECTED_ADMIN_CIDR -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=999.1.2.3/32 CURL_SCENARIO=timeout TCP_SCENARIO=closed -- blocked
has 'ERROR: set EXPECTED_ADMIN_CIDR'; lacks '^PASS'; done_case

run_case "azure-validate: non-numeric CONNECT_TIMEOUT -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 CONNECT_TIMEOUT=abc -- blocked
has 'ERROR: CONNECT_TIMEOUT must be a whole number'; lacks '^PASS'; done_case

run_case "azure-validate: unexpected extra argument -> exit 2" 2 azure-validate.sh EXPECTED_ADMIN_CIDR=198.51.100.20/32 -- blocked --force
has "unexpected argument '--force'"; lacks '^PASS'; done_case

echo
echo "Script tests: $((cases - case_failures)) passed, ${case_failures} failed (of ${cases})"
exit $(( case_failures > 0 ? 1 : 0 ))
