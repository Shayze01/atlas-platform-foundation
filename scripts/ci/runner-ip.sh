#!/usr/bin/env bash
# Prints this machine's public IPv4 as a /32, only if two independent services
# agree and the address is a valid public unicast IPv4. Otherwise exits 2 so no
# NSG rule is ever created for a wrong or wider address.
set -uo pipefail
octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
get() { curl -4 -sS --max-time 10 "$1" 2>/dev/null | tr -d '[:space:]'; }
a="$(get https://api.ipify.org)"; b="$(get https://ifconfig.me/ip)"
[[ "${a}" =~ ^${octet}(\.${octet}){3}$ ]] || { echo "ERROR: could not determine public IPv4 (service 1)" >&2; exit 2; }
[[ "${a}" == "${b}" ]] || { echo "ERROR: IP services disagree; refusing to open access" >&2; exit 2; }
case "${a}" in
  0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|2[2-5][0-9].*)
    echo "ERROR: ${a} is not a public unicast address" >&2; exit 2 ;;
esac
printf '%s/32\n' "${a}"
