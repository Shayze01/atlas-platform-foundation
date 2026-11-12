#!/usr/bin/env bash
# Post-deployment checks. Run from the machine whose IP is admin_source_ip_cidr,
# AFTER 'terraform apply'. Reads the VM address from Terraform outputs.
set -euo pipefail
cd "$(dirname "$0")/.."

SSH_KEY="${SSH_KEY:-$HOME/.ssh/atlas_admin}"
IP=$(terraform output -raw public_ip_address)
USER_NAME=$(terraform output -raw ssh_command | sed -E 's/.* ([^@ ]+)@.*/\1/')

echo "VM public IP: ${IP}"
echo "Your current public IP: $(curl -4 -s --max-time 5 https://ifconfig.me || echo unknown)"

echo; echo "==> TCP port checks"
for port in 22 80; do
  if timeout 5 bash -c "</dev/tcp/${IP}/${port}" 2>/dev/null; then
    echo "PASS: port ${port} reachable"
  else
    echo "FAIL: port ${port} not reachable (NSG source IP? VM running? see README troubleshooting)"
  fi
done

echo; echo "==> HTTP checks"
curl -s -o /dev/null -w "GET /        -> HTTP %{http_code}\n" --max-time 10 "http://${IP}/" || true
curl -s -w "\nGET /health  -> HTTP %{http_code}\n" --max-time 10 "http://${IP}/health" || true

echo; echo "==> SSH checks (key authentication)"
ssh -i "${SSH_KEY}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${USER_NAME}@${IP}" \
  'cloud-init status --long; echo; docker ps --filter name=atlas-web; echo; curl -s http://127.0.0.1/health; echo' || \
  echo "FAIL: SSH connection failed (see README troubleshooting)"

echo; echo "==> Password authentication must be refused"
if ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=yes \
     -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${USER_NAME}@${IP}" true 2>/dev/null; then
  echo "FAIL: password authentication appears to be accepted"
else
  echo "PASS: password authentication refused"
fi
