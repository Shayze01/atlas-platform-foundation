#!/usr/bin/env bash
# Builds the Atlas Service Desk image (tickets-app/) and tests it locally:
#   1. unit tests inside the image (exact pinned dependencies)
#   2. container hardening and healthcheck
#   3. independent API flow check (tests/app/flow_check.py)
#   4. browser check (Playwright/Chromium in a pinned test image)
#   5. ticket data survives a container restart (data volume) and is removed with it
# Requires Docker. Does NOT contact Azure. Binds to 127.0.0.1 only.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="atlas-tickets:local-test"
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
}
trap cleanup EXIT
cleanup

failures=0
check() {
  local description="$1"; shift
  if "$@"; then echo "PASS: ${description}"; else echo "FAIL: ${description}"; failures=$((failures + 1)); fi
}

start_container() {
  docker run -d --name "${CONTAINER}" \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --memory 256m --pids-limit 100 \
    -v "${VOLUME}:/var/lib/atlas-tickets" \
    -e ATLAS_ENVIRONMENT=local-test -e ATLAS_EXPIRES_AT="${EXPIRES_AT}" \
    -p "127.0.0.1:${HOST_PORT}:8080" "${IMAGE}" >/dev/null
  for _ in $(seq 1 30); do
    curl -fsS "${BASE_URL}/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  docker logs "${CONTAINER}" || true
  return 1
}

echo "Building ${IMAGE} and ${UI_IMAGE} (log: build/test-tickets-local.log) ..."
revision=$(git rev-parse HEAD 2>/dev/null || echo unknown)
if ! { docker build --target healthy -t "${IMAGE}" --build-arg REVISION="${revision}" \
         --build-arg BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" tickets-app &&
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

echo
if (( failures > 0 )); then echo "${failures} ticket-app check(s) failed"; exit 1; fi
echo "All ticket-app local checks passed."
