#!/usr/bin/env bash
# Renders the cloud-init template exactly as Terraform would (no Azure access
# needed) and writes it to build/cloud-init.rendered.yaml for inspection and
# schema validation.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN_USERNAME="${1:-atlasadmin}"
mkdir -p build

# Placeholder values only satisfy the required variables; they do not affect
# the rendered cloud-init apart from the admin username, image and expiry.
echo 'local.cloud_init' | terraform console \
  -var "owner=render-check" \
  -var "admin_username=${ADMIN_USERNAME}" \
  -var "admin_ssh_public_key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPlaceholderPlaceholderPlaceholder00 render" \
  -var "admin_source_ip_cidr=203.0.113.10/32" \
  -var "app_image=${APP_IMAGE:-ghcr.io/shayze01/atlas-tickets@sha256:0000000000000000000000000000000000000000000000000000000000000000}" \
  -var "app_variant=healthy" \
  -var "expires_at=${EXPIRES_AT:-2030-01-01T00:00:00Z}" \
  | sed -e '1{/^<<EOT$/d}' -e '${/^EOT$/d}' > build/cloud-init.rendered.yaml

echo "Rendered: build/cloud-init.rendered.yaml"
