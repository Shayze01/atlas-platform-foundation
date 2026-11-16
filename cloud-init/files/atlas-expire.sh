#!/usr/bin/env bash
# Guest app stop at ATLAS_EXPIRES_AT (atlas-expiry.timer, and the boot-time check in
# run-tickets.sh). Stops the app and deletes the ticket data so the URL stops
# answering. It does NOT delete Azure resources or stop billing: that is done by the
# in-job destroy, failure-cleanup, the hourly sweep or the nightly Destroy.
# Success is reported only after Docker confirms the container and the ticket-data
# volume are absent. Exit 0 verified absent (also when already absent); 1 removal or
# verification failed (the unit then shows as failed).
set -uo pipefail
CONTAINER=atlas-tickets
VOLUME=atlas-tickets-data
ERR="$(mktemp)"; trap 'rm -f "${ERR}"' EXIT
failed=0

# Removal errors are not fatal on their own ("already absent" is fine); absence is verified below.
docker rm -f "${CONTAINER}" >/dev/null 2>"${ERR}" || echo "atlas: removing container ${CONTAINER} reported: $(head -n 1 "${ERR}")"
docker volume rm -f "${VOLUME}" >/dev/null 2>"${ERR}" || echo "atlas: removing volume ${VOLUME} reported: $(head -n 1 "${ERR}")"
systemctl disable atlas-tickets.service >/dev/null 2>&1 || true

# absent <kind> <name>: 0 only when Docker answers "no such <kind>".
absent() {
  if docker "$1" inspect "$2" >/dev/null 2>"${ERR}"; then
    echo "atlas: FAIL - ${1} ${2} still exists"; return 1
  elif grep -qi "no such ${1}" "${ERR}"; then
    return 0
  fi
  echo "atlas: FAIL - cannot verify ${1} ${2} is absent: $(head -n 1 "${ERR}")"; return 1
}
absent container "${CONTAINER}" || failed=1
absent volume "${VOLUME}" || failed=1
if (( failed )); then
  echo "atlas: expiry cleanup NOT verified; the app or its ticket data may remain" >&2
  exit 1
fi

STATE_DIR="${ATLAS_STATE_DIR:-/var/lib/atlas}"
mkdir -p "${STATE_DIR}" && date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/expired"
echo "atlas: expired - container and ticket-data volume verified absent; Azure resources are NOT deleted by this"
