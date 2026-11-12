#!/usr/bin/env bash
# Builds and runs the web container locally (same script the VM uses) and
# checks the landing page and /health endpoint. Requires Docker.
#
# Optional: BASE_IMAGE=mirror.gcr.io/nginxinc/nginx-unprivileged:1.30-alpine
# if Docker Hub rate-limits you.
set -euo pipefail
cd "$(dirname "$0")/.."

export IMAGE_NAME="atlas-web:local-test"
export CONTAINER_NAME="atlas-web-local-test"
export BIND_ADDRESS="127.0.0.1"
export HOST_PORT="${HOST_PORT:-8088}"
BASE_URL="http://${BIND_ADDRESS}:${HOST_PORT}"

cleanup() { docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

failures=0
# check <description> <command...>: runs the command and records PASS/FAIL.
check() {
  local description="$1"; shift
  if "$@"; then
    echo "PASS: ${description}"
  else
    echo "FAIL: ${description}"
    failures=$((failures + 1))
  fi
}

echo "Building and starting container (log: build/test-web-local.log) ..."
mkdir -p build
if ! ./app/run-container.sh >build/test-web-local.log 2>&1; then
  cat build/test-web-local.log
  exit 1
fi

echo "Waiting for ${BASE_URL}/health ..."
for _ in $(seq 1 30); do
  curl -fsS "${BASE_URL}/health" >/dev/null 2>&1 && break
  sleep 1
done

health_code=$(curl -s -o build/health.out -w '%{http_code}' "${BASE_URL}/health")
check "/health returns HTTP 200 (got ${health_code})" test "${health_code}" = "200"
check "/health body reports ok: $(cat build/health.out)" grep -q '"status":"ok"' build/health.out

index_code=$(curl -s -o build/index.out -w '%{http_code}' "${BASE_URL}/")
check "/ returns HTTP 200 (got ${index_code})" test "${index_code}" = "200"
check "/ displays 'Atlas Platform Foundation'" grep -q 'Atlas Platform Foundation' build/index.out

missing_code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/does-not-exist")
check "unknown path returns HTTP 404 (got ${missing_code})" test "${missing_code}" = "404"

server_header=$(curl -sI "${BASE_URL}/" | tr -d '\r' | grep -i '^server:' || true)
check "nginx version hidden (${server_header})" test "${server_header,,}" = "server: nginx"

uid=$(docker exec "${CONTAINER_NAME}" id -u)
check "container runs as non-root (uid ${uid})" test "${uid}" != "0"

readonly_rootfs=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${CONTAINER_NAME}")
check "container root filesystem is read-only" test "${readonly_rootfs}" = "true"

echo "Waiting for Docker HEALTHCHECK ..."
status="unknown"
for _ in $(seq 1 20); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER_NAME}")
  [[ "${status}" == "healthy" ]] && break
  sleep 2
done
check "Docker HEALTHCHECK reports healthy (got ${status})" test "${status}" = "healthy"

echo
if (( failures > 0 )); then
  echo "${failures} check(s) failed"; exit 1
fi
echo "All local web service checks passed."
