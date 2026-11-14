#!/usr/bin/env bash
# Waits until http://<vm>/health answers 200 from this runner (cloud-init builds the
# container on first boot). Prints no addresses. Exit 0 ready, 1 timed out, 2 error.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
MAX_SECONDS="${MAX_SECONDS:-900}"
ip="$(terraform output -raw public_ip_address 2>/dev/null)" || { echo "ERROR: Terraform output public_ip_address unavailable"; exit 2; }
[[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "ERROR: invalid public_ip_address output"; exit 2; }
start=${SECONDS}
while (( SECONDS - start < MAX_SECONDS )); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://${ip}/health" 2>/dev/null || true)"
  if [[ "${code}" == 200 ]]; then echo "Web service healthy after $((SECONDS - start))s"; exit 0; fi
  echo "waiting for /health (last HTTP ${code:-none}, $((SECONDS - start))s elapsed)"
  sleep 15
done
echo "FAIL: /health did not return 200 within ${MAX_SECONDS}s"; exit 1
