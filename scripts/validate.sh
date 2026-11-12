#!/usr/bin/env bash
# Runs every offline check. Needs Terraform (>= 1.7); Docker and cloud-init are
# optional and skipped if missing. Does NOT contact or change Azure.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { echo; echo "==> $*"; }

step "terraform fmt -check -recursive"
terraform fmt -check -recursive -diff

step "terraform init -backend=false"
terraform init -backend=false -input=false >/dev/null && echo "init OK"

step "terraform validate"
terraform validate

step "terraform test (mocked provider, no Azure calls)"
terraform test

step "Render cloud-init"
./scripts/render-cloud-init.sh

step "Rendered cloud-init embeds ./app files unchanged"
python3 scripts/check-cloud-init-files.py

if command -v cloud-init >/dev/null 2>&1; then
  step "cloud-init schema validation"
  cloud-init schema --config-file build/cloud-init.rendered.yaml
else
  echo "SKIP: cloud-init not installed; schema validation skipped"
fi

if command -v shellcheck >/dev/null 2>&1; then
  step "shellcheck"
  shellcheck app/*.sh scripts/*.sh && echo "shellcheck OK"
else
  echo "SKIP: shellcheck not installed"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  step "Local web service test"
  ./scripts/test-web-local.sh
else
  echo "SKIP: Docker not available; local web service test skipped"
fi

echo
echo "All available offline checks passed."
