#!/usr/bin/env bash
# Offline tests for the in-guest scripts embedded by cloud-init:
# cloud-init/files/run-tickets.sh (start by digest + boot-time expiry check) and
# cloud-init/files/atlas-expire.sh (guest app stop). docker and systemctl are stubs.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="${ROOT}/tests/scripts/stubs-guest"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export STUB_LOG="${WORK}/calls.log"
IMG="ghcr.io/shayze01/atlas-tickets@sha256:$(printf 'a%.0s' {1..64})"
FUTURE="2099-01-01T00:00:00Z" PAST="2000-01-01T00:00:00Z"
cases=0 failures=0 ok=true OUT="" RC=0

# run_guest <name> <expected exit> <script> <image> <expires> [VAR=value ...]
run_guest() {
  local name="$1" expected="$2" script="$3" img="$4" exp="$5"; shift 5
  NAME="${name}"; cases=$((cases + 1)); ok=true; : >"${STUB_LOG}"; rm -rf "${WORK}/state"
  { [[ -n "${img}" ]] && echo "ATLAS_IMAGE=${img}"; [[ -n "${exp}" ]] && echo "ATLAS_EXPIRES_AT=${exp}"; echo "ATLAS_ENVIRONMENT=azure-dev"; } >"${WORK}/env"
  OUT="$(env PATH="${STUBS}:${PATH}" ATLAS_ENV_FILE="${WORK}/env" ATLAS_STATE_DIR="${WORK}/state" \
           ATLAS_EXPIRE_SCRIPT="${ROOT}/cloud-init/files/atlas-expire.sh" "$@" \
           "${ROOT}/cloud-init/files/${script}" 2>&1)"
  RC=$?
  [[ "${RC}" == "${expected}" ]] || note "expected exit ${expected}, got ${RC}"
}
note() { ok=false; echo "    - $1"; }
called()     { grep -qE -- "$1" "${STUB_LOG}" || note "expected call /$1/"; }
not_called() { if grep -qE -- "$1" "${STUB_LOG}"; then note "unexpected call /$1/"; fi; }
has()        { grep -qE -- "$1" <<<"${OUT}" || note "output missing /$1/"; }
done_case() {
  if [[ "${ok}" == true ]]; then echo "PASS: ${NAME}"; else
    echo "FAIL: ${NAME}"; sed 's/^/      | /' "${STUB_LOG}"; printf '      | %s\n' "${OUT}"; failures=$((failures + 1)); fi
}

run_guest "start: unexpired, digest matches -> pulls by digest, runs hardened on :80" 0 run-tickets.sh "${IMG}" "${FUTURE}"
called "^docker pull ${IMG}$"; called "^docker run -d --name atlas-tickets --restart no --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges"
called "-p 80:8080 ${IMG}$"; called "ATLAS_EXPIRES_AT=${FUTURE}"; not_called "volume rm"; done_case

run_guest "boot after expiry: app never started, data deleted, service disabled" 0 run-tickets.sh "${IMG}" "${PAST}"
has "expired at ${PAST}; not starting"; not_called "docker (pull|run)"; called "^docker rm -f atlas-tickets$"
called "^docker volume rm -f atlas-tickets-data$"; called "^systemctl disable atlas-tickets.service$"
[[ -s "${WORK}/state/expired" ]] || note "expired marker not written"; done_case

SOON="$(date -u -d '+2 seconds' +%Y-%m-%dT%H:%M:%SZ)"
run_guest "pull spans expiry -> app not started, guest app stop runs instead" 0 run-tickets.sh "${IMG}" "${SOON}" DOCKER_PULL_SECONDS=3
called "^docker pull"; not_called "^docker run"; called "^docker volume rm -f atlas-tickets-data$"; has "not starting the app"; done_case

run_guest "malformed expiry -> refuses to start, no docker calls" 1 run-tickets.sh "${IMG}" "2026-11-16 22:30"
has "missing or malformed"; not_called "^docker"; done_case

run_guest "impossible date (month 13) -> refuses to start" 1 run-tickets.sh "${IMG}" "2026-13-01T00:00:00Z"
has "missing or malformed"; not_called "^docker"; done_case

run_guest "missing expiry -> refuses to start" 1 run-tickets.sh "${IMG}" ""
has "missing or malformed"; not_called "^docker"; done_case

# shellcheck disable=SC2016 # deliberately literal: must never be expanded
run_guest "env file is parsed, never executed (command substitution stays inert)" 1 run-tickets.sh "${IMG}" '$(touch /tmp/atlas-pwned)'
has "missing or malformed"; not_called "^docker"; [[ ! -e /tmp/atlas-pwned ]] || note "env file content was executed"; done_case

run_guest "mutable tag instead of digest -> refuses to pull" 1 run-tickets.sh "ghcr.io/shayze01/atlas-tickets:latest" "${FUTURE}"
has "not a pinned digest"; not_called "^docker"; done_case

run_guest "image from another namespace -> refuses to pull" 1 run-tickets.sh "ghcr.io/someone/atlas-tickets@sha256:$(printf 'a%.0s' {1..64})" "${FUTURE}"
not_called "^docker"; done_case

run_guest "pulled image lacks the planned digest -> not run" 1 run-tickets.sh "${IMG}" "${FUTURE}" DOCKER_DIGEST_SCENARIO=mismatch
has "does not carry the planned digest"; not_called "^docker run"; done_case

run_guest "guest app stop (timer): stops app, deletes data, never touches Azure" 0 atlas-expire.sh "${IMG}" "${PAST}"
called "^docker rm -f atlas-tickets$"; called "^docker volume rm -f atlas-tickets-data$"; not_called "^(az|terraform) "
has "Azure resources are NOT deleted"; done_case

echo; echo "Guest expiry tests: $((cases - failures))/${cases} passed"
(( failures == 0 ))
