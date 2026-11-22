#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( $1 != advertised && $1 != withdrawn ) ]]; then
  printf 'Usage: %s advertised|withdrawn\n' "${0##*/}" >&2
  exit 2
fi

spine=clab-ovn-bgp-spine
leaf=clab-ovn-bgp-leaf
fip=198.51.100.100
probe=203.0.113.10

wait_for_routes() {
  local summary routes
  summary=$(docker exec "$leaf" vtysh -c 'show bgp ipv4 unicast summary json')
  routes=$(docker exec "$spine" vtysh -c "show bgp ipv4 unicast $fip/32 json")

  jq -e '
    [.peers[]? | .state == "Established"] == [true, true]
  ' <<< "$summary" >/dev/null || return 1

  case "$1" in
    advertised)
      jq -e 'any(.paths[]?; .valid and .bestpath.overall)' <<< "$routes" >/dev/null &&
        docker exec "$spine" ping -I "$probe" -c 3 -W 2 "$fip"
      ;;
    withdrawn)
      jq -e 'type == "object" and ((.paths // []) | length == 0)' <<< "$routes" >/dev/null
      ;;
  esac
}

for (( attempt = 0; attempt < 30; attempt++ )); do
  if wait_for_routes "$1"; then
    printf 'Floating IP %s/32 %s\n' "$fip" "$1"
    exit 0
  fi
  sleep 2
done

docker exec "$leaf" vtysh -c 'show bgp ipv4 unicast summary' >&2
docker exec "$spine" vtysh -c "show bgp ipv4 unicast $fip/32" >&2
printf 'Floating IP %s/32 did not become %s\n' "$fip" "$1" >&2
exit 1
