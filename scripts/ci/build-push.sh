#!/usr/bin/env bash
# Builds the ticket-app image for a Deploy scenario, pushes it to GHCR and prints the
# exact digest reference. No Azure access. The fault build is produced ONLY for the
# deliberate-failure scenario; the variant label of the built image is verified.
#
# Usage: scripts/ci/build-push.sh healthy|deliberate-failure-ignore-status
# Environment: GH_TOKEN (GITHUB_TOKEN with packages: write), GITHUB_ACTOR, GITHUB_SHA.
# Writes app_image and app_variant to $GITHUB_OUTPUT. Exit 0 ok, 1 build/push failed, 2 bad input.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
REPO="ghcr.io/shayze01/atlas-tickets"
case "${1:-}" in
  healthy) variant=healthy ;;
  deliberate-failure-ignore-status) variant=broken-ignore-status ;;
  *) echo "ERROR: unknown scenario '${1:-}'"; exit 2 ;;
esac
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: GITHUB_SHA must be a full commit SHA"; exit 2; }
[[ -n "${GH_TOKEN:-}" && -n "${GITHUB_ACTOR:-}" ]] || { echo "ERROR: GH_TOKEN and GITHUB_ACTOR are required"; exit 2; }
tag="${REPO}:${GITHUB_SHA:0:12}-${variant}"

printf '%s' "${GH_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin >/dev/null || { echo "ERROR: GHCR login failed"; exit 1; }
docker build --target "${variant}" \
  --build-arg REVISION="${GITHUB_SHA}" --build-arg BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t "${tag}" tickets-app || { echo "ERROR: docker build failed"; exit 1; }
label="$(docker image inspect -f '{{index .Config.Labels "atlas.variant"}}' "${tag}")"
[[ "${label}" == "${variant}" ]] || { echo "ERROR: built image is labelled '${label}', expected '${variant}'"; exit 1; }
docker push "${tag}" >/dev/null || { echo "ERROR: docker push failed"; exit 1; }
ref="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "${tag}" | grep -m1 "^${REPO}@sha256:")"
[[ "${ref}" =~ ^ghcr\.io/shayze01/atlas-tickets@sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: no digest reference after push"; exit 1; }
echo "Built and pushed ${variant}: ${ref} (tag ${tag})"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "app_image=${ref}"; echo "app_variant=${variant}"; } >>"${GITHUB_OUTPUT}"
fi
