#!/usr/bin/env bash
# Starts the Atlas Service Desk container from the exact image digest in
# /etc/atlas/tickets.env. Run by atlas-tickets.service at every boot, so it is also
# the boot-time expiry check: once ATLAS_EXPIRES_AT has passed it never starts the
# app and runs the guest app stop instead (e.g. a VM started again after expiry).
set -euo pipefail
ENV_FILE="${ATLAS_ENV_FILE:-/etc/atlas/tickets.env}"
# Parsed, never sourced: values are data and are validated below.
ATLAS_IMAGE="" ATLAS_EXPIRES_AT="" ATLAS_ENVIRONMENT=""
while IFS='=' read -r key value; do
  case "${key}" in
    ATLAS_IMAGE|ATLAS_EXPIRES_AT|ATLAS_ENVIRONMENT) printf -v "${key}" '%s' "${value}" ;;
  esac
done <"${ENV_FILE}"
CONTAINER=atlas-tickets
VOLUME=atlas-tickets-data

if [[ ! "${ATLAS_EXPIRES_AT:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
   ! expires="$(date -u -d "${ATLAS_EXPIRES_AT}" +%s 2>/dev/null)"; then
  echo "atlas: ATLAS_EXPIRES_AT is missing or malformed; refusing to start" >&2
  exit 1
fi
# Checked before the pull, again just before starting, and once more after starting, so
# a slow pull that spans ExpiresAt (after the timer already fired) cannot leave the app up.
stop_if_expired() {
  if (( $(date -u +%s) >= expires )); then
    echo "atlas: environment expired at ${ATLAS_EXPIRES_AT}; not starting the app"
    exec "${ATLAS_EXPIRE_SCRIPT:-/opt/atlas/atlas-expire.sh}"
  fi
}
stop_if_expired

if [[ ! "${ATLAS_IMAGE:-}" =~ ^ghcr\.io/shayze01/atlas-tickets@sha256:[0-9a-f]{64}$ ]]; then
  echo "atlas: ATLAS_IMAGE is not a pinned digest reference; refusing to start" >&2
  exit 1
fi
docker pull "${ATLAS_IMAGE}"
if ! docker image inspect --format '{{join .RepoDigests "\n"}}' "${ATLAS_IMAGE}" | grep -qxF "${ATLAS_IMAGE}"; then
  echo "atlas: pulled image does not carry the planned digest" >&2
  exit 1
fi
stop_if_expired
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" --restart no \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --memory 256m --pids-limit 100 \
  -v "${VOLUME}:/var/lib/atlas-tickets" \
  -e ATLAS_ENVIRONMENT="${ATLAS_ENVIRONMENT:-azure}" -e ATLAS_EXPIRES_AT="${ATLAS_EXPIRES_AT}" \
  -p 80:8080 "${ATLAS_IMAGE}"
stop_if_expired
