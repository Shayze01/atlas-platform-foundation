#!/usr/bin/env bash
# Builds and (re)starts the Atlas web container. Used by cloud-init on the VM
# and by scripts/test-web-local.sh, so both run the container the same way.
set -euo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
IMAGE_NAME="${IMAGE_NAME:-atlas-web:1.0}"
CONTAINER_NAME="${CONTAINER_NAME:-atlas-web}"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
HOST_PORT="${HOST_PORT:-80}"
BUILD_ARGS=()
if [[ -n "${BASE_IMAGE:-}" ]]; then
  BUILD_ARGS+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")
fi

# Retry the build because pulling the base image can fail transiently
# (network not ready yet, registry rate limits).
for attempt in 1 2 3 4 5; do
  if docker build "${BUILD_ARGS[@]}" -t "${IMAGE_NAME}" "${APP_DIR}"; then
    break
  fi
  if [[ "${attempt}" -eq 5 ]]; then
    echo "docker build failed after ${attempt} attempts" >&2
    exit 1
  fi
  echo "docker build failed (attempt ${attempt}); retrying in 15s..." >&2
  sleep 15
done

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --memory 128m \
  --pids-limit 100 \
  -p "${BIND_ADDRESS}:${HOST_PORT}:8080" \
  "${IMAGE_NAME}"
