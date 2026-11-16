#!/usr/bin/env bash
# Runs every offline check and prints a PASS / FAIL / SKIP summary.
# Needs Terraform (>= 1.7). Docker, cloud-init, shellcheck, actionlint and PyYAML are
# optional locally; their checks are reported as SKIP if the tool is missing.
# REQUIRE_ALL=1 (used in CI) turns every SKIP into a failure, so a missing tool
# can never make the run look complete.
# Does NOT contact or change Azure.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

results=()
failed=0

# run_step <name> <command...>
run_step() {
  local name="$1"; shift
  echo; echo "==> ${name}"
  if "$@"; then
    results+=("PASS | ${name}")
  else
    results+=("FAIL | ${name}")
    failed=$((failed + 1))
  fi
}

skip_step() {
  echo; echo "==> $1"; echo "SKIP: $2"
  results+=("SKIP | $1 ($2)")
}

docker_available() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

run_step "terraform fmt -check -recursive" terraform fmt -check -recursive -diff
run_step "terraform init -backend=false" terraform init -backend=false -input=false -no-color
run_step "terraform validate" terraform validate -no-color
run_step "terraform test (mocked provider, no Azure calls)" terraform test -no-color
run_step "Render cloud-init" ./scripts/render-cloud-init.sh
run_step "Rendered cloud-init: exact image digest, expiry timer, embedded scripts" python3 scripts/check-cloud-init-files.py

if command -v cloud-init >/dev/null 2>&1; then
  run_step "cloud-init schema validation" cloud-init schema --config-file build/cloud-init.rendered.yaml
else
  skip_step "cloud-init schema validation" "cloud-init not installed"
fi

run_step "Expiry-tag carriers and state-to-Azure mapping tests" python3 tests/expiry/test_expiry_map.py
run_step "Guest expiry script tests (stubbed docker/systemctl)" ./tests/scripts/test-guest-expiry.sh
run_step "Script behaviour tests (stubbed az/terraform/curl/ssh, no network)" ./tests/scripts/run-script-tests.sh

if python3 -c 'import yaml' >/dev/null 2>&1; then
  run_step "Workflow security policy tests" python3 tests/workflows/test_workflow_policy.py
else
  skip_step "Workflow security policy tests" "PyYAML not installed"
fi

if command -v actionlint >/dev/null 2>&1; then
  run_step "actionlint (GitHub Actions workflows)" actionlint
else
  skip_step "actionlint (GitHub Actions workflows)" "actionlint not installed"
fi

if command -v shellcheck >/dev/null 2>&1; then
  run_step "shellcheck" shellcheck app/run-container.sh cloud-init/files/*.sh scripts/*.sh scripts/ci/*.sh scripts/github/*.sh \
    bootstrap/*.sh tests/scripts/*.sh tests/scripts/stubs/* tests/scripts/stubs-m2/* tests/scripts/stubs-guest/*
else
  skip_step "shellcheck" "shellcheck not installed"
fi

if docker_available; then
  run_step "Local web service test (Docker)" ./scripts/test-web-local.sh
else
  skip_step "Local web service test (Docker)" "Docker not available"
fi

if docker_available; then
  run_step "Ticket app: unit, API flow and browser tests (Docker)" ./scripts/test-tickets-local.sh
else
  skip_step "Ticket app: unit, API flow and browser tests (Docker)" "Docker not available"
fi

echo
echo "================ Summary ================"
printf '%s\n' "${results[@]}"
pass_count=$(printf '%s\n' "${results[@]}" | grep -c '^PASS' || true)
skip_count=$(printf '%s\n' "${results[@]}" | grep -c '^SKIP' || true)
echo "Passed: ${pass_count}  Failed: ${failed}  Skipped: ${skip_count}"
echo "Azure deployment checks are NOT part of this script (see README sections 7-9)."
if [[ "${REQUIRE_ALL:-0}" == 1 ]] && (( skip_count > 0 )); then
  echo "FAIL: REQUIRE_ALL=1 and ${skip_count} check(s) were skipped (missing tools above)."
  failed=$((failed + skip_count))
fi

exit $(( failed > 0 ? 1 : 0 ))
