#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  advertised|withdrawn|reachable) check=$1 ;;
  *) printf 'Usage: %s advertised|withdrawn|reachable\n' "${0##*/}" >&2; exit 2 ;;
esac

spine=clab-ovn-bgp-spine
leaf=clab-ovn-bgp-leaf
fixed_ip=10.53.0.22
probe=203.0.113.10

check_routes() {
  local summary bgp fib vrf default_route
  summary=$(docker exec "$leaf" vtysh -c 'show bgp ipv4 unicast summary json') || return 1
  jq -e '.peers | keys == ["eth1", "eth2"] and all(.[]; .state == "Established" and .idType == "interface")' <<< "$summary" >/dev/null || return 1

  bgp=$(docker exec "$spine" vtysh -c "show bgp ipv4 unicast $fixed_ip/32 json") || return 1
  fib=$(docker exec "$spine" ip -j -4 route show exact "$fixed_ip/32") || return 1
  vrf=$(ip -j -4 route show table 42 exact "$fixed_ip/32") || return 1
  default_route=$(ip -j -4 route show table 10 default) || return 1
  jq -e '
    length == 1 and all(.[]; .protocol == "bgp" and .via.family == "inet6" and .dev == "br-bgp-0")
  ' <<< "$default_route" >/dev/null || return 1

  case "$check" in
    advertised|reachable)
      jq -e 'any(.paths[]?; .valid and .bestpath.overall)' <<< "$bgp" >/dev/null &&
        jq -e 'any(.[]; .protocol == "bgp" and .dev == "eth1" and .via.family == "inet6")' <<< "$fib" >/dev/null &&
        jq -e 'any(.[]; .protocol == "ovn")' <<< "$vrf" >/dev/null
      ;;
    withdrawn)
      jq -e 'type == "object" and ((.paths // []) | length == 0)' <<< "$bgp" >/dev/null &&
        jq -e 'length == 0' <<< "$fib" >/dev/null &&
        jq -e 'length == 0' <<< "$vrf" >/dev/null
      ;;
  esac
}

for ((attempt = 0; attempt < 30; attempt++)); do
  if check_routes; then
    if [[ $check == reachable ]]; then
      docker exec "$spine" ping -I "$probe" -c 3 -W 2 "$fixed_ip"
    fi
    printf 'Tenant fixed IP %s/32 %s\n' "$fixed_ip" "$check"
    exit 0
  fi
  sleep 2
done

docker exec "$leaf" vtysh -c 'show bgp ipv4 unicast summary' >&2
docker exec "$spine" vtysh -c "show bgp ipv4 unicast $fixed_ip/32" >&2
printf 'Tenant fixed IP %s/32 did not become %s\n' "$fixed_ip" "$check" >&2
exit 1
