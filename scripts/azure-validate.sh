#!/usr/bin/env bash
# Post-deployment validation that does NOT need the administrator's private key.
#
#   public   Public-endpoint checks from the machine running this script:
#            HTTP status/body for / and /health, and a no-key SSH probe that must
#            be refused with "Permission denied (publickey)". The source address
#            must be allowed by the NSG.
#   in-vm    Checks executed INSIDE the VM through Azure Run Command (Azure API,
#            no SSH): cloud-init, container health, local /health, effective
#            sshd configuration, installed admin key fingerprint and outbound IP.
#   blocked  After the temporary test rule is removed: NSG rules must be exactly
#            the intended set, and HTTP/SSH from this machine must no longer connect.
#
# None of these is a key-based SSH login test; that needs the private key and is
# done with scripts/connectivity-check.sh from the administrator's laptop.
#
# Environment:
#   ADMIN_PUBKEY_FILE    .pub file whose fingerprint must be in authorized_keys (in-vm)
#   EXPECTED_ADMIN_CIDR  admin /32 expected on the SSH/HTTP rules (blocked)
#   CONNECT_TIMEOUT, HTTP_TIMEOUT  seconds (default 10)
#
# Exit codes: 0 all checks passed, 1 a check failed, 2 could not start.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

MODE="${1:-}"
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

case "${MODE}" in
  public|in-vm|blocked) ;;
  *) echo "Usage: $0 public|in-vm|blocked"; exit 2 ;;
esac

tf_out() {
  local v
  v="$(terraform output -raw "$1" 2>"${WORK}/err")" || { echo "ERROR: Terraform output '$1' unavailable: $(first_line "${WORK}/err")"; exit 2; }
  printf '%s' "${v}"
}
IP="$(tf_out public_ip_address)" || exit 2
if [[ ! "${IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "ERROR: invalid public_ip_address output '${IP}'"; exit 2
fi
RG="$(tf_out resource_group_name)" || exit 2
VM="$(tf_out vm_name)" || exit 2
USER_NAME="$(sed -nE 's/.* ([a-z_][a-z0-9_-]*)@[0-9.]+$/\1/p' <<<"$(tf_out ssh_command)")"
NSG="nsg-${RG#rg-}"
echo "== ${MODE} checks for ${VM} (${IP}) in ${RG}"

# ------------------------------------------------------------------ public
http_check() {
  local path="$1" pattern="$2" what="$3" code rc
  code="$(curl -sS -o "${WORK}/body" -w '%{http_code}' --max-time "${HTTP_TIMEOUT}" "http://${IP}${path}" 2>"${WORK}/err")"
  rc=$?
  if (( rc != 0 )); then
    fail "GET ${path}: request failed (curl exit ${rc}: $(first_line "${WORK}/err"))"
    return
  fi
  if [[ "${code}" == "200" ]]; then pass "GET ${path} returned HTTP 200"; else fail "GET ${path} returned HTTP ${code}, expected 200"; fi
  if grep -qE "${pattern}" "${WORK}/body"; then pass "GET ${path} body contains ${what}"; else fail "GET ${path} body does not contain ${what}"; fi
}

if [[ "${MODE}" == public ]]; then
  echo "Source address seen by the Internet: $(curl -4 -s --max-time "${HTTP_TIMEOUT}" https://api.ipify.org || echo unknown)"
  http_check "/"       'Atlas Platform Foundation' "'Atlas Platform Foundation'"
  http_check "/health" '"status": *"ok"' '"status":"ok"'
  probe="$(ssh -o "ConnectTimeout=${CONNECT_TIMEOUT}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
             -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
             "${USER_NAME}@${IP}" true 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    fail "SSH login without a key succeeded"
  elif grep -q 'Permission denied (publickey)' <<<"${probe}"; then
    pass "SSH server refuses non-key login and offers only 'publickey'"
  elif grep -q 'Permission denied (' <<<"${probe}"; then
    fail "SSH server offers other methods: $(grep -o 'Permission denied ([^)]*)' <<<"${probe}")"
  else
    fail "inconclusive - no SSH authentication answer ($(head -n 1 <<<"${probe}")); a timeout does not prove anything"
  fi
fi

# ------------------------------------------------------------------ in-vm
if [[ "${MODE}" == in-vm ]]; then
  expected_fp=""
  if [[ -n "${ADMIN_PUBKEY_FILE:-}" ]]; then
    expected_fp="$(ssh-keygen -lf "${ADMIN_PUBKEY_FILE}" 2>/dev/null | awk '{print $2}')"
    [[ -n "${expected_fp}" ]] || { echo "ERROR: cannot read fingerprint of ${ADMIN_PUBKEY_FILE}"; exit 2; }
  fi
  cat >"${WORK}/in-vm.sh" <<SCRIPT
echo "CLOUD_INIT=\$(cloud-init status 2>&1 | head -n 1)"
echo "CONTAINER_HEALTH=\$(docker inspect -f '{{.State.Health.Status}}' ${CONTAINER_NAME} 2>&1 | head -n 1)"
echo "LOCAL_HEALTH_CODE=\$(curl -s -o /tmp/atlas-health -w '%{http_code}' --max-time 5 http://127.0.0.1/health)"
echo "LOCAL_HEALTH_BODY=\$(tr -d '\n' </tmp/atlas-health 2>/dev/null)"
sshd -T -C user=${USER_NAME},host=validation,addr=192.0.2.1 2>&1 | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) ' | awk '{print "SSHD_" \$1 "=" \$2}'
echo "AUTHORIZED_KEY_FPS=\$(ssh-keygen -lf /home/${USER_NAME}/.ssh/authorized_keys 2>/dev/null | awk '{print \$2}' | paste -sd, -)"
echo "OUTBOUND_IP=\$(curl -4 -s --max-time 10 https://api.ipify.org)"
SCRIPT
  if ! az vm run-command invoke -g "${RG}" -n "${VM}" --command-id RunShellScript \
        --scripts @"${WORK}/in-vm.sh" --query 'value[0].message' -o tsv >"${WORK}/rc.out" 2>"${WORK}/err"; then
    fail "Azure Run Command failed; no in-VM result was obtained: $(first_line "${WORK}/err")"
  else
    sed -n '/^\[stdout\]/,/^\[stderr\]/p' "${WORK}/rc.out" | grep '=' >"${WORK}/kv" || true
    val() { sed -n "s/^$1=//p" "${WORK}/kv" | head -n 1; }
    expect() { # key expected description
      local got; got="$(val "$1")"
      if [[ "${got}" == "$2" ]]; then pass "in-VM: $3 ($1=${got})"; else fail "in-VM: $3 - expected $1=$2, got '${got:-<missing>}'"; fi
    }
    expect CLOUD_INIT "status: done" "cloud-init finished"
    expect CONTAINER_HEALTH "healthy" "container ${CONTAINER_NAME} healthy"
    expect LOCAL_HEALTH_CODE "200" "local /health returns HTTP 200"
    if grep -qE '"status": *"ok"' <<<"$(val LOCAL_HEALTH_BODY)"; then pass "in-VM: local /health body contains \"status\":\"ok\""; else fail "in-VM: local /health body is '$(val LOCAL_HEALTH_BODY)'"; fi
    expect SSHD_passwordauthentication no "effective sshd: password authentication disabled"
    expect SSHD_kbdinteractiveauthentication no "effective sshd: keyboard-interactive disabled"
    expect SSHD_permitrootlogin no "effective sshd: root login disabled"
    expect SSHD_pubkeyauthentication yes "effective sshd: public-key authentication enabled"
    if [[ -n "${expected_fp}" ]]; then
      if [[ ",$(val AUTHORIZED_KEY_FPS)," == *",${expected_fp},"* ]]; then
        pass "in-VM: administrator public key ${expected_fp} is in authorized_keys"
      else
        fail "in-VM: ${expected_fp} not in authorized_keys (found '$(val AUTHORIZED_KEY_FPS)')"
      fi
    fi
    expect OUTBOUND_IP "${IP}" "outbound traffic leaves via the NIC's Standard public IP"
  fi
fi

# ------------------------------------------------------------------ blocked
if [[ "${MODE}" == blocked ]]; then
  if [[ ! "${EXPECTED_ADMIN_CIDR:-}" =~ /32$ ]]; then echo "ERROR: set EXPECTED_ADMIN_CIDR to the admin /32"; exit 2; fi
  if az network nsg rule list -g "${RG}" --nsg-name "${NSG}" \
       --query "sort_by([], &priority)[].[name, access, sourceAddressPrefix, join(',', sourceAddressPrefixes), destinationPortRange]" \
       -o tsv >"${WORK}/rules" 2>"${WORK}/err"; then
    sed 's/^/    /' "${WORK}/rules"
    expected_rules="$(printf 'Allow-SSH-From-Admin\tAllow\t%s\t\t22\nAllow-HTTP-From-Admin\tAllow\t%s\t\t80\nDeny-Internet-Inbound\tDeny\tInternet\t\t*\n' "${EXPECTED_ADMIN_CIDR}" "${EXPECTED_ADMIN_CIDR}")"
    if [[ "$(tr -d '\r' <"${WORK}/rules")" == "${expected_rules}" ]]; then
      pass "NSG has exactly the intended rules (admin ${EXPECTED_ADMIN_CIDR} on 22/80, Internet deny) and no temporary rule"
    else
      fail "NSG rules differ from the intended set"
    fi
  else
    fail "could not list NSG rules: $(first_line "${WORK}/err")"
  fi
  curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT}" "http://${IP}/health" >/dev/null 2>"${WORK}/err"
  rc=$?
  case "${rc}" in
    0) fail "HTTP from this machine still connects; access is NOT blocked" ;;
    7|28) pass "HTTP from this machine no longer connects (curl exit ${rc})" ;;
    *) fail "HTTP check inconclusive (curl exit ${rc}: $(first_line "${WORK}/err"))" ;;
  esac
  if timeout "${CONNECT_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${IP}/22" 2>/dev/null; then
    fail "TCP 22 from this machine still connects; access is NOT blocked"
  else
    pass "TCP 22 from this machine no longer connects"
  fi
fi

echo
echo "RESULT (${MODE}): ${passed} passed, ${failed} failed"
(( failed == 0 )) || exit 1
