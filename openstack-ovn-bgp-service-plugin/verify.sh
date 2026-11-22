#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:$#" in
  advertised:1|withdrawn:1|reachable:1|failover:1) check=$1 ;;
  *) echo "Usage: $0 {advertised|withdrawn|reachable|failover}" >&2; exit 2 ;;
esac

spine=clab-ovn-bgp-spine
leaves=(clab-ovn-bgp-leaf1 clab-ovn-bgp-leaf2)
fixed_ip=10.53.0.22
node_ip=203.0.113.31
probe=203.0.113.10

check_peers() {
  docker exec "$1" vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e '
      .peers | keys == ["eth1","eth2"] and all(.[]; .state == "Established" and .idType == "interface")
    ' >/dev/null
}

check_fib() {
  local interfaces=$1
  shift
  "$@" | jq -e --argjson interfaces "$interfaces" '
    [.[] | select(.protocol == "bgp") | (.nexthops // [.])[] |
      select(.via.family == "inet6") | .dev] | sort == ($interfaces | sort)
  ' >/dev/null
}

check_routes() {
  local spine_interfaces=$1 bridges=$2 leaf
  shift 2
  check_fib "$bridges" ip -j -4 route show table 10 default || return 1
  check_fib "$spine_interfaces" docker exec "$spine" ip -j -4 route show exact "$node_ip/32" || return 1
  if [[ $check == withdrawn ]]; then
    ip -j -4 route show table 42 exact "$fixed_ip/32" |
      jq -e 'length == 0' >/dev/null || return 1
    for leaf in "$@" "$spine"; do
      docker exec "$leaf" ip -j -4 route show exact "$fixed_ip/32" |
        jq -e 'length == 0' >/dev/null || return 1
    done
  else
    ip -j -4 route show table 42 exact "$fixed_ip/32" |
      jq -e 'any(.[]; .protocol == "ovn")' >/dev/null || return 1
    check_fib "$spine_interfaces" docker exec "$spine" ip -j -4 route show exact "$fixed_ip/32" || return 1
    for leaf in "$@"; do
      check_fib '["eth1"]' docker exec "$leaf" ip -j -4 route show exact "$node_ip/32" || return 1
      check_fib '["eth1"]' docker exec "$leaf" ip -j -4 route show exact "$fixed_ip/32" || return 1
    done
  fi
}

wait_for_routes() {
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if check_routes "$@"; then return 0; fi
    sleep 2
  done
  ip -4 route show table 10 >&2
  ip -4 route show table 42 >&2
  docker exec "$spine" vtysh -c "show bgp ipv4 unicast $fixed_ip/32" >&2
  return 1
}

wait_for_dual_tor() {
  wait_for_routes '["eth1","eth2"]' '["br-bgp-0","br-bgp-1"]' "${leaves[@]}"
}

check_traffic() {
  docker exec "$spine" ping -I "$probe" -c 3 -W 2 "$node_ip"
  docker exec "$spine" ping -I "$probe" -c 3 -W 2 "$fixed_ip"
}

ip -j -4 address show dev lo | jq -e --arg ip "$node_ip" \
  'any(.[].addr_info[]; .local == $ip and .prefixlen == 32)' >/dev/null
wait_for_dual_tor
for router in "${leaves[@]}" "$spine"; do check_peers "$router"; done

case "$check" in
  advertised|withdrawn)
    printf 'VM fixed IP %s/32 %s on both ToRs\n' "$fixed_ip" "$check"
    ;;
  reachable)
    check_traffic
    ;;
  failover)
    trap 'docker exec "$leaf" ip link set eth1 up' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for leaf in "${leaves[@]}"; do
      docker exec "$leaf" ip link set eth1 down
      if [[ $leaf == "${leaves[0]}" ]]; then
        wait_for_routes '["eth2"]' '["br-bgp-1"]' "${leaves[1]}"
      else
        wait_for_routes '["eth1"]' '["br-bgp-0"]' "${leaves[0]}"
      fi
      check_traffic
      docker exec "$leaf" ip link set eth1 up
      wait_for_dual_tor
    done
    trap - EXIT INT TERM
    printf 'VM fixed IP %s/32 remained advertised on each surviving ToR\n' "$fixed_ip"
    ;;
esac
