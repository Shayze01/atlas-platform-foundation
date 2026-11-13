#!/usr/bin/env bash
# Post-deployment checks. Run from the machine whose IP is admin_source_ip_cidr,
# AFTER 'terraform apply'. Reads the VM address from Terraform outputs.
#
# Every check is required. A check passes only on positive evidence; timeouts and
# connection failures are always FAIL, never proof that something is disabled.
#
# Environment:
#   SSH_KEY          private key path (default ~/.ssh/atlas_admin)
#   CONNECT_TIMEOUT  seconds for TCP/SSH connects (default 10)
#   HTTP_TIMEOUT     seconds per HTTP request (default 10)
#
# Exit codes: 0 all checks passed, 1 at least one check failed,
#             2 could not start (Terraform outputs or SSH key missing).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

SSH_KEY="${SSH_KEY:-$HOME/.ssh/atlas_admin}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-10}"
CONTAINER_NAME="atlas-web"

passed=0
failed=0
pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------- setup
IP="$(terraform output -raw public_ip_address 2>"${WORK}/err")"
if [[ ! "${IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "ERROR: could not read a valid 'public_ip_address' Terraform output: $(first_line "${WORK}/err")"
  echo "Run this script from the repository folder after 'terraform apply'."
  exit 2
fi
SSH_CMD="$(terraform output -raw ssh_command 2>"${WORK}/err")"
USER_NAME="$(sed -nE 's/.* ([a-z_][a-z0-9_-]*)@[0-9.]+$/\1/p' <<<"${SSH_CMD}")"
if [[ -z "${USER_NAME}" ]]; then
  echo "ERROR: could not read the admin username from the 'ssh_command' output: $(first_line "${WORK}/err")"
  exit 2
fi
if [[ ! -r "${SSH_KEY}" ]]; then
  echo "ERROR: SSH private key not found or not readable: ${SSH_KEY} (set SSH_KEY=...)"
  exit 2
fi

echo "VM public IP:          ${IP}"
echo "Admin user:            ${USER_NAME}"
echo "Your current public IP: $(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || echo unknown) (informational)"

# ---------------------------------------------------------------- TCP
echo; echo "==> TCP port checks"
for port in 22 80; do
  if timeout "${CONNECT_TIMEOUT}" bash -c "</dev/tcp/${IP}/${port}" 2>/dev/null; then
    pass "TCP ${port} reachable"
  else
    fail "TCP ${port} not reachable within ${CONNECT_TIMEOUT}s (NSG source IP? VM running? see README troubleshooting)"
  fi
done

# ---------------------------------------------------------------- HTTP
echo; echo "==> HTTP checks"
# http_check <path> <grep -E pattern for body> <body description>
http_check() {
  local path="$1" pattern="$2" what="$3" code rc
  code="$(curl -sS -o "${WORK}/body" -w '%{http_code}' --max-time "${HTTP_TIMEOUT}" \
            "http://${IP}${path}" 2>"${WORK}/err")"
  rc=$?
  if (( rc != 0 )); then
    fail "GET ${path}: request failed (curl exit ${rc}: $(first_line "${WORK}/err"))"
    fail "GET ${path}: body not checked because the request failed"
    return
  fi
  if [[ "${code}" == "200" ]]; then
    pass "GET ${path} returned HTTP 200"
  else
    fail "GET ${path} returned HTTP ${code}, expected 200"
  fi
  if grep -qE "${pattern}" "${WORK}/body"; then
    pass "GET ${path} body contains ${what}"
  else
    fail "GET ${path} body does not contain ${what} (got: $(first_line "${WORK}/body"))"
  fi
}
http_check "/"       'Atlas Platform Foundation' "'Atlas Platform Foundation'"
http_check "/health" '"status": *"ok"'           '"status":"ok"'

# ---------------------------------------------------------------- SSH
echo; echo "==> SSH key authentication"
SSH_COMMON=(-o "ConnectTimeout=${CONNECT_TIMEOUT}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
ssh_key() {
  ssh "${SSH_COMMON[@]}" -i "${SSH_KEY}" -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
      "${USER_NAME}@${IP}" "$@"
}

key_ok=false
out="$(ssh_key 'echo atlas-key-auth-ok' 2>"${WORK}/err")"
rc=$?
if (( rc == 0 )) && [[ "${out}" == "atlas-key-auth-ok" ]]; then
  pass "key-authenticated SSH session established"
  key_ok=true
else
  fail "key-authenticated SSH session failed (ssh exit ${rc}: $(first_line "${WORK}/err"))"
fi

echo; echo "==> Checks inside the VM (over the key-authenticated session)"
SSHD_EXPECT=("passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin no" "pubkeyauthentication yes")
if [[ "${key_ok}" == true ]]; then
  out="$(ssh_key 'cloud-init status' 2>"${WORK}/err")"
  rc=$?
  if (( rc == 0 )) && grep -qx 'status: done' <<<"${out}"; then
    pass "cloud-init finished (status: done)"
  else
    fail "cloud-init not finished cleanly (exit ${rc}, output: $(head -n 1 <<<"${out}")); run 'cloud-init status --long' on the VM"
  fi

  out="$(ssh_key "sudo -n docker inspect --format '{{.State.Health.Status}}' ${CONTAINER_NAME}" 2>"${WORK}/err")"
  rc=$?
  if (( rc == 0 )) && [[ "${out}" == "healthy" ]]; then
    pass "container ${CONTAINER_NAME} health is 'healthy'"
  else
    fail "container ${CONTAINER_NAME} health is '${out:-unknown}' (exit ${rc}: $(first_line "${WORK}/err"))"
  fi

  out="$(ssh_key 'sudo -n install -d -m 0755 /run/sshd && sudo -n sshd -T' 2>"${WORK}/err")"
  rc=$?
  for setting in "${SSHD_EXPECT[@]}"; do
    if (( rc == 0 )) && grep -qix "${setting}" <<<"${out}"; then
      pass "effective sshd config: ${setting}"
    elif (( rc != 0 )); then
      fail "effective sshd config not readable ('sudo sshd -T' exit ${rc}); '${setting}' not verified"
    else
      fail "effective sshd config: expected '${setting}', got '$(grep -i "^${setting%% *} " <<<"${out}" || echo missing)'"
    fi
  done
else
  fail "cloud-init status not verified: no key-authenticated session"
  fail "container health not verified: no key-authenticated session"
  for setting in "${SSHD_EXPECT[@]}"; do
    fail "effective sshd config '${setting}' not verified: no key-authenticated session"
  done
fi

echo; echo "==> Authentication methods offered by the SSH server"
# Supporting evidence only: the server must answer and list publickey as its
# ONLY method. A timeout or refused connection proves nothing and is a FAIL.
probe="$(ssh "${SSH_COMMON[@]}" -o PubkeyAuthentication=no \
          -o PreferredAuthentications=password,keyboard-interactive \
          "${USER_NAME}@${IP}" true 2>&1 >/dev/null)"
rc=$?
if (( rc == 0 )); then
  fail "login without a key succeeded"
elif grep -q 'Permission denied (publickey)' <<<"${probe}"; then
  pass "server rejects non-key login and offers only 'publickey'"
elif grep -q 'Permission denied (' <<<"${probe}"; then
  fail "server offers other authentication methods: $(grep -o 'Permission denied ([^)]*)' <<<"${probe}")"
else
  fail "inconclusive - server did not answer the authentication probe ($(head -n 1 <<<"${probe}")); a timeout or failed connection does not prove password authentication is disabled"
fi

echo
echo "Passed: ${passed}  Failed: ${failed}"
if (( failed > 0 )); then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS - all connectivity checks passed."
