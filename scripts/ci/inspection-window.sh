#!/usr/bin/env bash
# Owner inspection window: keeps the environment up for exactly INSPECTION_MINUTES,
# printing the remaining time. Prints times only - never the URL or any address (the
# URL is delivered privately). End early by cancelling the run: failure-cleanup then
# destroys the workload. Runs only after the pre-window lifetime gate passed.
# Environment: INSPECTION_MINUTES (15|30|45), EXPIRES_AT, TICK_SECONDS (default 300).
set -uo pipefail
[[ "${INSPECTION_MINUTES:-}" =~ ^(15|30|45)$ ]] || { echo "ERROR: INSPECTION_MINUTES must be 15, 30 or 45"; exit 2; }
[[ "${EXPIRES_AT:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "ERROR: EXPIRES_AT malformed"; exit 2; }
TICK="${TICK_SECONDS:-300}"
start="$(date -u +%s)"; end=$((start + INSPECTION_MINUTES * 60))
fmt() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
summary() {
  echo "### Inspection window"
  echo
  echo "| Time (UTC) | Meaning |"
  echo "| --- | --- |"
  echo "| $(fmt "${start}") | window start: runner access removed and confirmed blocked; only your /32 can connect |"
  echo "| $(fmt "${end}") | inspection end: in-job destroy starts (normally done within about 10 min) |"
  echo "| ${EXPIRES_AT} | guest app stop on the VM (only if the VM is running); ExpiresAt for the hourly sweep from +15 min |"
  echo
  echo "URL: delivered privately. Network access stays restricted by the NSG to the owner's /32."
  echo "No time above is a guarantee that resources are deleted by then; see docs for delays and limits."
}
summary
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && summary >>"${GITHUB_STEP_SUMMARY}"
while (( $(date -u +%s) < end )); do
  left=$(( end - $(date -u +%s) ))
  echo "Inspection window: $(( (left + 59) / 60 )) min left (ends $(fmt "${end}"))"
  sleep $(( left < TICK ? left : TICK ))
done
echo "Inspection window ended at $(fmt "$(date -u +%s)") after ${INSPECTION_MINUTES} min."
