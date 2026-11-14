#!/usr/bin/env bash
# Filter for public CI logs: masks IPv4 addresses, GUIDs (subscription, tenant,
# object IDs), SSH public keys/fingerprints and SAS-style signatures. GitHub also
# masks secret values; this catches values that are not stored as secrets.
# Usage: some-command 2>&1 | scripts/ci/sanitize.sh
set -uo pipefail
exec perl -pe '
  s{\b(ssh-(?:ed25519|rsa)|ecdsa-sha2-nistp\d+) [A-Za-z0-9+/=]{20,}}{$1 <public-key>}g;
  s{SHA256:[A-Za-z0-9+/]{43}=?}{SHA256:<fingerprint>}g;
  s{\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b}{<guid>}g;
  s{(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?![\d.])}{<ip>}g;
  s{([?&]sig=)[^&\s"]+}{$1<redacted>}g;
'
