#!/usr/bin/env bash
# Installs the optional offline-check tools on a GitHub-hosted Ubuntu runner so
# validate.sh (REQUIRE_ALL=1) can run every check. actionlint is checksum-verified.
set -euo pipefail
ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends cloud-init shellcheck python3-yaml jq >/dev/null

bin="${RUNNER_TEMP:-/tmp}/bin"; mkdir -p "${bin}"
tgz="${RUNNER_TEMP:-/tmp}/actionlint.tgz"
curl -sSL -o "${tgz}" "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
echo "${ACTIONLINT_SHA256}  ${tgz}" | sha256sum -c --quiet
tar -xzf "${tgz}" -C "${bin}" actionlint
[[ -n "${GITHUB_PATH:-}" ]] && echo "${bin}" >>"${GITHUB_PATH}"
"${bin}/actionlint" -version | head -n 1
cloud-init --version
shellcheck --version | sed -n 2p
