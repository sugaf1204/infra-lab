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
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if node "$1" vtysh -c 'show bgp ipv4 unicast summary json' |
      jq --exit-status --argjson interfaces "$2" '
        .peers as $p | all($interfaces[]; $p[.].state == "Established" and $p[.].idType == "interface")
      ' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  printf 'BGP ピアの確立を確認できませんでした (%s)。\n' "$1" >&2
  return 1
}

check_no_nat_leak() {
  local target
  for target in leaf1 leaf2 node0 node1; do
    if ! docker inspect "$lab_prefix-$target" >/dev/null 2>&1; then continue; fi
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

check_leaf_traffic() {
  local leaf=$1 other_leaf_ip=$2 target
  shift 2
  for target in "$other_leaf_ip" "$@" "$external_probe"; do
    node "$leaf" ping -c 2 -W 2 "$target"
  done
}

check_traffic() {
  check_leaf_traffic leaf1 10.211.255.2 "$@"
  check_leaf_traffic leaf2 10.211.255.1 "$@"
}

case "${1:-}" in
  ""|--failover) ;;
  *) echo "Usage: $0 [--failover]" >&2; exit 2 ;;
esac

check_dual_spine() {
  local router
  check_peers nat '["eth1","eth2"]'
  for router in leaf1 leaf2; do
    wait_for_nexthops "$router" 0.0.0.0/0 '["eth1","eth2"]'
    check_peers "$router" '["eth1","eth2"]'
  done
  for router in spine1 spine2; do
    check_peers "$router" '["eth1","eth2","eth3"]'
    wait_for_nexthops "$router" 10.211.255.1/32 '["eth1"]'
    wait_for_nexthops "$router" 10.211.255.2/32 '["eth2"]'
  done
  check_no_nat_leak
  check_traffic 10.211.255.3 10.211.255.4
}

set_spine_leaf_links() {
  node "$1" ip link set eth1 "$2"
  node "$1" ip link set eth2 "$2"
}

check_dual_spine

if [[ ${1:-} == --failover ]]; then
  trap 'set_spine_leaf_links "$spine" up' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for spine in spine1 spine2; do
    if [[ $spine == spine1 ]]; then
      remaining='["eth2"]'
      surviving_ip=10.211.255.4
    else
      remaining='["eth1"]'
      surviving_ip=10.211.255.3
    fi
    set_spine_leaf_links "$spine" down
    for leaf in leaf1 leaf2; do
      wait_for_nexthops "$leaf" 0.0.0.0/0 "$remaining"
    done
    check_traffic "$surviving_ip"
    set_spine_leaf_links "$spine" up
    check_dual_spine
  done
  trap - EXIT INT TERM
fi
