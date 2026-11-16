#!/usr/bin/env bash
# Builds the Atlas Service Desk image (tickets-app/) and tests it locally:
#   1. unit tests inside the image (exact pinned dependencies)
#   2. container hardening and healthcheck
#   3. independent API flow check (tests/app/flow_check.py)
#   4. browser check (Playwright/Chromium in a pinned test image)
#   5. ticket data survives a container restart (data volume) and is removed with it
#   6. test-the-test: the DELIBERATE FAULT BUILD (target broken-ignore-status) must make
#      the same independent API and browser checks fail with a status mismatch, and the
#      healthy image must contain none of the fault code
# Requires Docker. Does NOT contact Azure. Binds to 127.0.0.1 only.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="atlas-tickets:local-test"
BROKEN_IMAGE="atlas-tickets:local-test-broken-ignore-status"
DEFAULT_IMAGE="atlas-tickets:local-test-default-target"
BROKEN_CONTAINER="atlas-tickets-local-test-broken"
BROKEN_VOLUME="atlas-tickets-local-test-broken-data"
BROKEN_PORT="${BROKEN_PORT:-8088}"
BROKEN_URL="http://127.0.0.1:${BROKEN_PORT}"
UI_IMAGE="atlas-tickets-ui-test:local"
CONTAINER="atlas-tickets-local-test"
VOLUME="atlas-tickets-local-test-data"
HOST_PORT="${HOST_PORT:-8089}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
EXPIRES_AT="2099-01-01T00:00:00Z"
mkdir -p build

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
  docker rm -f "${BROKEN_CONTAINER}" >/dev/null 2>&1 || true
  docker volume rm "${BROKEN_VOLUME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

failures=0
check() {
  local description="$1"; shift
  if "$@"; then echo "PASS: ${description}"; else echo "FAIL: ${description}"; failures=$((failures + 1)); fi
}

# run_hardened NAME VOLUME PORT IMAGE: start a container with the production hardening flags.
run_hardened() {
  docker run -d --name "$1" \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --memory 256m --pids-limit 100 \
    -v "$2:/var/lib/atlas-tickets" \
    -e ATLAS_ENVIRONMENT=local-test -e ATLAS_EXPIRES_AT="${EXPIRES_AT}" \
    -p "127.0.0.1:$3:8080" "$4" >/dev/null
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$3/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  docker logs "$1" || true
  return 1
}

indent_output() { local line; while IFS= read -r line; do printf '  | %s\n' "${line}"; done <<<"$1"; }

start_container() { run_hardened "${CONTAINER}" "${VOLUME}" "${HOST_PORT}" "${IMAGE}"; }

echo "Building ${IMAGE}, ${BROKEN_IMAGE} and ${UI_IMAGE} (log: build/test-tickets-local.log) ..."
revision=$(git rev-parse HEAD 2>/dev/null || echo unknown)
build_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_args=(--build-arg REVISION="${revision}" --build-arg BUILD_TIME="${build_time}")
if ! { docker build --target healthy -t "${IMAGE}" "${build_args[@]}" tickets-app &&
       docker build --target broken-ignore-status -t "${BROKEN_IMAGE}" "${build_args[@]}" tickets-app &&
       docker build -t "${DEFAULT_IMAGE}" "${build_args[@]}" tickets-app &&
       docker build -t "${UI_IMAGE}" tests/app/ui; } >build/test-tickets-local.log 2>&1; then
  cat build/test-tickets-local.log; exit 1
fi

echo "== Unit tests (inside the image)"
check "unit tests pass" docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --network none \
  -v "${PWD}/tests/app/unit:/tests:ro" "${IMAGE}" python -m unittest discover -s /tests

echo "== Container"
start_container
check "/health returns ok" bash -c "curl -fsS '${BASE_URL}/health' | grep -q '\"status\":\"ok\"'"
version=$(curl -fsS "${BASE_URL}/version")
check "/version reports variant healthy" grep -q '"variant":"healthy"' <<<"${version}"
check "/version reports revision ${revision:0:12}" grep -q "\"revision\":\"${revision}\"" <<<"${version}"
label=$(docker inspect -f '{{index .Config.Labels "atlas.variant"}}' "${IMAGE}")
check "image label atlas.variant=healthy (got ${label})" test "${label}" = "healthy"
uid=$(docker exec "${CONTAINER}" id -u)
check "container runs as non-root (uid ${uid})" test "${uid}" != "0"
check "root filesystem is read-only" test "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${CONTAINER}")" = "true"
check "no write access outside the data volume and /tmp" bash -c "! docker exec '${CONTAINER}' touch /app/x 2>/dev/null"
check "all capabilities dropped" test "$(docker inspect -f '{{.HostConfig.CapDrop}}' "${CONTAINER}")" = "[ALL]"
check "unknown path returns 404" test "$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/nope")" = "404"
check "form posts rejected (JSON only, 415)" test "$(curl -s -o /dev/null -w '%{http_code}' \
  -d 'title=x' "${BASE_URL}/api/tickets")" = "415"

echo "== Independent API flow check"
set +e
python3 tests/app/flow_check.py --base-url "${BASE_URL}" --label "LOCAL-TEST"
flow_rc=$?
set -e
check "flow check exit code 0 (got ${flow_rc})" test "${flow_rc}" = 0

echo "== Browser check (Playwright, Chromium)"
set +e
docker run --rm --network host --ipc host --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "${PWD}/tests/app/ui:/ui:ro" -v "${PWD}/build:/out" "${UI_IMAGE}" \
  python3 /ui/ui_check.py --base-url "${BASE_URL}" --label "LOCAL-TEST" --expect-expiry --screenshots /out/ui-screenshots
ui_rc=$?
set -e
check "browser check exit code 0 (got ${ui_rc})" test "${ui_rc}" = 0

echo "== Ticket data lifecycle"
count_before=$(curl -fsS "${BASE_URL}/api/tickets" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tickets"]))')
docker rm -f "${CONTAINER}" >/dev/null
start_container
count_after=$(curl -fsS "${BASE_URL}/api/tickets" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tickets"]))')
check "tickets kept across a container restart (${count_before} -> ${count_after})" test "${count_before}" = "${count_after}"
docker rm -f "${CONTAINER}" >/dev/null
docker volume rm "${VOLUME}" >/dev/null
start_container
count_fresh=$(curl -fsS "${BASE_URL}/api/tickets" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tickets"]))')
check "removing the data volume deletes tickets (fresh start: ${count_fresh} seed tickets)" test "${count_fresh}" = 6

echo "Waiting for Docker HEALTHCHECK ..."
status=unknown
for _ in $(seq 1 20); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}")
  [[ "${status}" == healthy ]] && break
  sleep 2
done
check "Docker HEALTHCHECK reports healthy (got ${status})" test "${status}" = healthy

echo "== Healthy image excludes the deliberate fault"
default_label=$(docker inspect -f '{{index .Config.Labels "atlas.variant"}}' "${DEFAULT_IMAGE}")
check "a build without --target is healthy (label ${default_label})" test "${default_label}" = healthy
check "healthy image has no atlas.deliberate-fault label" \
  test -z "$(docker inspect -f '{{index .Config.Labels "atlas.deliberate-fault"}}' "${IMAGE}")"
check "healthy image contains no fault module or fault code" docker run --rm --network none \
  --entrypoint sh "${IMAGE}" -c '! find / -xdev -name "fault_*" 2>/dev/null | grep -q . &&
    ! grep -rIlE "ignore_status|DELIBERATE FAULT|broken-ignore-status" /app'

echo "== Test-the-test: DELIBERATE FAULT BUILD (broken-ignore-status)"
broken_label=$(docker inspect -f '{{index .Config.Labels "atlas.variant"}}' "${BROKEN_IMAGE}")
check "broken image label atlas.variant=broken-ignore-status (got ${broken_label})" \
  test "${broken_label}" = broken-ignore-status
# shellcheck disable=SC2016 # the $(find ...) runs inside the container
check "broken image adds exactly one fault module (/app/fault_ignore_status.py)" \
  docker run --rm --network none --entrypoint sh "${BROKEN_IMAGE}" -c \
  'test -f /app/fault_ignore_status.py && test "$(find / -xdev -name "fault_*" 2>/dev/null)" = /app/fault_ignore_status.py'
run_hardened "${BROKEN_CONTAINER}" "${BROKEN_VOLUME}" "${BROKEN_PORT}" "${BROKEN_IMAGE}"
check "/version reports variant broken-ignore-status" \
  bash -c "curl -fsS '${BROKEN_URL}/version' | grep -q '\"variant\":\"broken-ignore-status\"'"
check "/api/environment carries the DELIBERATE FAULT BUILD warning" \
  bash -c "curl -fsS '${BROKEN_URL}/api/environment' | grep -q 'DELIBERATE FAULT BUILD - status updates are ignored'"

set +e
broken_flow=$(python3 tests/app/flow_check.py --base-url "${BROKEN_URL}" --label "LOCAL-FAULT-TEST" 2>&1)
broken_flow_rc=$?
set -e
indent_output "${broken_flow}"
check "flow check FAILS against the fault build with exit 3 (got ${broken_flow_rc})" test "${broken_flow_rc}" = 3
check "flow check reports expected 'In progress', got 'Open'" \
  grep -qF "FAIL: status mismatch: expected 'In progress', got 'Open'" <<<"${broken_flow}"

set +e
broken_ui=$(docker run --rm --network host --ipc host --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "${PWD}/tests/app/ui:/ui:ro" -v "${PWD}/build:/out" "${UI_IMAGE}" \
  python3 /ui/ui_check.py --base-url "${BROKEN_URL}" --label "LOCAL-FAULT-TEST" --expect-expiry \
  --screenshots /out/ui-screenshots-broken 2>&1)
broken_ui_rc=$?
set -e
indent_output "${broken_ui}"
check "browser check FAILS against the fault build with exit 3 (got ${broken_ui_rc})" test "${broken_ui_rc}" = 3
check "browser check reports expected 'In progress', got 'Open' after reload" \
  grep -qF "FAIL: status mismatch after reload: expected 'In progress', got 'Open'" <<<"${broken_ui}"

fault_confined() {
  local id
  id=$(curl -fsS -H 'Content-Type: application/json' -d '{"title":"Fault scope check","requester":"Fault Check (fictional)"}' \
    "${BROKEN_URL}/api/tickets" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  curl -fsS -X PATCH -H 'Content-Type: application/json' -d '{"priority":"High"}' "${BROKEN_URL}/api/tickets/${id}" >/dev/null
  curl -fsS "${BROKEN_URL}/api/tickets/${id}" | python3 -c 'import json,sys; t=json.load(sys.stdin); sys.exit(0 if t["priority"]=="High" and t["status"]=="Open" else 1)'
}
check "fault is confined to status: priority updates still save on the fault build" fault_confined
docker rm -f "${BROKEN_CONTAINER}" >/dev/null
docker volume rm "${BROKEN_VOLUME}" >/dev/null

echo
if (( failures > 0 )); then echo "${failures} ticket-app check(s) failed"; exit 1; fi
echo "All ticket-app local checks passed."
