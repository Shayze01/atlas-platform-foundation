#!/usr/bin/env bash
# Guest app stop at ATLAS_EXPIRES_AT (atlas-expiry.timer, and the boot-time check in
# run-tickets.sh). Stops the app and deletes the ticket data so the URL stops
# answering. It does NOT delete Azure resources or stop billing: that is done by the
# in-job destroy, failure-cleanup, the hourly sweep or the nightly Destroy.
set -uo pipefail
docker rm -f atlas-tickets >/dev/null 2>&1 || true
docker volume rm -f atlas-tickets-data >/dev/null 2>&1 || true
systemctl disable atlas-tickets.service >/dev/null 2>&1 || true
STATE_DIR="${ATLAS_STATE_DIR:-/var/lib/atlas}"
mkdir -p "${STATE_DIR}" && date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/expired"
echo "atlas: expired - app stopped and ticket data deleted; Azure resources are NOT deleted by this"
