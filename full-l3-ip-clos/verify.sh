#!/usr/bin/env bash
set -euo pipefail
lab_prefix=clab-full-l3-ip-clos
external_probe=${EXTERNAL_PROBE:-1.1.1.1}

node() {
  local name=$1
  shift
  docker exec "$lab_prefix-$name" "$@"
}

fabric_ip() {
  local router=$1 pid
  shift
  pid=$(docker inspect --format '{{.State.Pid}}' "$lab_prefix-$router")
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  nsenter --target "$pid" --net ip -j -4 route "$@"
}

expect_nexthops() {
  local router=$1 route=$2 interfaces=$3
  fabric_ip "$router" show exact "$route" |
    jq --exit-status --argjson interfaces "$interfaces" '
      [.[] | select(.protocol == "bgp") |
        (.nexthops // [.])[] |
        select(.via.family == "inet6" and (.via.host | startswith("fe80:"))) | .dev
      ] | sort == ($interfaces | sort)
    ' >/dev/null
}

wait_for_nexthops() {
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if expect_nexthops "$@"; then
      return 0
    fi
    sleep 2
  done
  printf '経路の収束を確認できませんでした (%s %s)。\n' "$1" "$2" >&2
  fabric_ip "$1" show exact "$2"
  return 1
}

check_peers() {
  node "$1" vtysh -c 'show bgp ipv4 unicast summary json' |
    jq --exit-status --argjson interfaces "$2" '
      .peers as $p | all($interfaces[]; $p[.].state == "Established" and $p[.].idType == "interface")
    ' >/dev/null
}

check_no_nat_leak() {
  local target
  for target in leaf1 leaf2 host1 host2; do
    if node "$target" vtysh -c 'show bgp ipv4 unicast' | grep -q '100\.64\.0\.'; then
      printf 'NAT IP が %s の BGP テーブルへ流出しています。\n' "$target" >&2
      return 1
    fi
    if fabric_ip "$target" show | grep -q '100\.64\.0\.'; then
      printf 'NAT IP が %s の FIB へ流出しています。\n' "$target" >&2
      return 1
    fi
  done
}

check_default_traffic() {
  local host=$1 target
  for target in "$2" 10.211.255.3 10.211.255.4 "$external_probe"; do
    fabric_ip "$host" get fibmatch "$target" |
      jq -e 'any(.[]; (.dst == "default" or .dst == "0.0.0.0/0") and .protocol == "bgp")' >/dev/null
    node "$host" ping -c 2 -W 2 "$target"
  done
}

check_traffic() {
  check_default_traffic host1 10.211.2.2
  check_default_traffic host2 10.211.1.2
}

case "${1:-}" in
  ""|--failover) ;;
  *) echo "Usage: $0 [--failover]" >&2; exit 2 ;;
esac

check_host_routes() {
  local interfaces=$1 host
  for host in host1 host2; do
    wait_for_nexthops "$host" 0.0.0.0/0 "$interfaces"
  done
}

check_dual_tor() {
  local host router
  check_peers nat '["eth1","eth2"]'
  for router in leaf1 leaf2; do
    wait_for_nexthops "$router" 0.0.0.0/0 '["eth1","eth2"]'
    wait_for_nexthops "$router" 10.211.1.2/32 '["eth3"]'
    wait_for_nexthops "$router" 10.211.2.2/32 '["eth4"]'
    check_peers "$router" '["eth1","eth2","eth3","eth4"]'
  done
  for router in spine1 spine2; do
    check_peers "$router" '["eth1","eth2","eth3"]'
    wait_for_nexthops "$router" 10.211.1.2/32 '["eth1","eth2"]'
    wait_for_nexthops "$router" 10.211.2.2/32 '["eth1","eth2"]'
  done
  check_host_routes '["eth1","eth2"]'
  for host in host1 host2; do
    check_peers "$host" '["eth1","eth2"]'
  done
  check_no_nat_leak
  check_traffic
}

set_tor_host_links() {
  node "$1" ip link set eth3 "$2"
  node "$1" ip link set eth4 "$2"
}

check_dual_tor

if [[ ${1:-} == --failover ]]; then
  trap 'set_tor_host_links "$tor" up' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for tor in leaf1 leaf2; do
    if [[ $tor == leaf1 ]]; then
      remaining='["eth2"]'
    else
      remaining='["eth1"]'
    fi
    set_tor_host_links "$tor" down
    check_host_routes "$remaining"
    for spine in spine1 spine2; do
      wait_for_nexthops "$spine" 10.211.1.2/32 "$remaining"
      wait_for_nexthops "$spine" 10.211.2.2/32 "$remaining"
    done
    check_traffic
    set_tor_host_links "$tor" up
    check_dual_tor
  done
  trap - EXIT INT TERM
fi
