#!/usr/bin/env bash
# Offline tests for scripts/ci/build-push.sh (stub docker) and
# scripts/ci/inspection-window.sh (fake clock): no network, no registry, no Azure.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="${ROOT}/tests/scripts/stubs-ci"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export STUB_LOG="${WORK}/calls.log" FAKE_CLOCK="${WORK}/clock"
SHA="0123456789abcdef0123456789abcdef01234567"
cases=0 failures=0 ok=true OUT="" RC=0 NAME=""

run() { # name expected script [VAR=value ...] -- args
  NAME="$1" expected="$2" script="$3"; shift 3
  local vars=() args=()
  while (( $# )); do [[ "$1" == -- ]] && { shift; args=("$@"); break; }; vars+=("$1"); shift; done
  cases=$((cases + 1)); ok=true; : >"${STUB_LOG}"; : >"${WORK}/gh_output"; echo 1794900000 >"${FAKE_CLOCK}"
  OUT="$(env PATH="${STUBS}:${PATH}" GITHUB_SHA="${SHA}" GITHUB_ACTOR=octo GH_TOKEN=t0ken GITHUB_OUTPUT="${WORK}/gh_output" \
           GITHUB_STEP_SUMMARY="${WORK}/summary" ${vars[@]+"${vars[@]}"} "${ROOT}/scripts/ci/${script}" ${args[@]+"${args[@]}"} 2>&1)"
  RC=$?
  [[ "${RC}" == "${expected}" ]] || note "expected exit ${expected}, got ${RC}"
}
note() { ok=false; echo "    - $1"; }
has() { grep -qE -- "$1" <<<"${OUT}" || note "output missing /$1/"; }
lacks() { if grep -qE -- "$1" <<<"${OUT}"; then note "output unexpectedly matches /$1/"; fi; }
called() { grep -qE -- "$1" "${STUB_LOG}" || note "expected call /$1/"; }
not_called() { if grep -qE -- "$1" "${STUB_LOG}"; then note "unexpected call /$1/"; fi; }
done_case() {
  if [[ "${ok}" == true ]]; then echo "PASS: ${NAME}"; else
    echo "FAIL: ${NAME}"; printf '      | %s\n' "${OUT}"; sed 's/^/      ~ /' "${STUB_LOG}"; failures=$((failures + 1)); fi
}

echo "== build-push.sh =="
run "healthy scenario builds the healthy target and outputs its digest" 0 build-push.sh -- healthy
called "^docker build --target healthy "; called "REVISION=${SHA}"; called "^docker push ghcr.io/shayze01/atlas-tickets:0123456789ab-healthy$"
grep -qx "app_image=ghcr.io/shayze01/atlas-tickets@sha256:$(printf 'c3%.0s' {1..32})" "${WORK}/gh_output" || note "app_image output missing"
grep -qx "app_variant=healthy" "${WORK}/gh_output" || note "app_variant output missing"; lacks "t0ken"; done_case

run "failure scenario (and only it) builds the fault target" 0 build-push.sh -- deliberate-failure-ignore-status
called "^docker build --target broken-ignore-status "; grep -qx "app_variant=broken-ignore-status" "${WORK}/gh_output" || note "variant"; done_case

run "unknown scenario -> exit 2, nothing built" 2 build-push.sh -- broken-ignore-status
not_called "^docker"; done_case

run "built image label does not match the variant -> exit 1, not pushed" 1 build-push.sh DOCKER_SCENARIO=wrong-label -- healthy
has "labelled 'healthy-but-wrong'"; not_called "^docker push"; [[ ! -s "${WORK}/gh_output" ]] || note "outputs written"; done_case

run "push fails -> exit 1, no outputs" 1 build-push.sh DOCKER_SCENARIO=push-fail -- healthy
[[ ! -s "${WORK}/gh_output" ]] || note "outputs written"; done_case

run "no digest after push -> exit 1" 1 build-push.sh DOCKER_SCENARIO=no-digest -- healthy
has "no digest reference"; done_case

run "registry login fails -> exit 1, nothing built" 1 build-push.sh DOCKER_SCENARIO=login-fail -- healthy
not_called "^docker build"; done_case

run "short GITHUB_SHA -> exit 2" 2 build-push.sh GITHUB_SHA=abc123 -- healthy
not_called "^docker"; done_case

echo; echo "== inspection-window.sh =="
run "15-min window runs in full, prints times only, never an address" 0 inspection-window.sh INSPECTION_MINUTES=15 EXPIRES_AT=2026-11-16T23:20:00Z
has "Inspection window: 15 min left"; has "Inspection window ended .* after 15 min"; has "URL: delivered privately"
called "^sleep 300$"; [[ "$(grep -c '^sleep' "${STUB_LOG}")" == 3 ]] || note "expected 3 ticks of 300 s"
grep -q "inspection end" "${WORK}/summary" || note "summary not written"; lacks "http://|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; done_case

run "window length other than 15/30/45 -> exit 2" 2 inspection-window.sh INSPECTION_MINUTES=10 EXPIRES_AT=2026-11-16T23:20:00Z
not_called "^sleep"; done_case

run "malformed expiry -> exit 2" 2 inspection-window.sh INSPECTION_MINUTES=30 EXPIRES_AT=tomorrow
not_called "^sleep"; done_case

echo; echo "CI helper tests: $((cases - failures))/${cases} passed"
(( failures == 0 ))
