#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:$#" in
  advertised:1|advertised:2|reachable:1|reachable:2|failover:1|failover:2|failover-routes:1|failover-routes:2|withdrawn:1|withdrawn:2|chassis:1) check=$1 ;;
  *) echo "Usage: $0 {advertised|reachable|failover|failover-routes} [controller|compute], withdrawn [VM_IP], or chassis" >&2; exit 2 ;;
esac

spine=clab-ovn-bgp-spine
leaves=(clab-ovn-bgp-leaf1 clab-ovn-bgp-leaf2)
node_ips=(203.0.113.31 203.0.113.32)
fixed_ips=(10.53.0.22 10.53.0.23)
node_ports=(eth1 eth3)
probe=203.0.113.10

check_peers() {
  docker exec "$1" vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e --argjson wanted "$2" '
      .peers as $peers | all($wanted[]; $peers[.].state == "Established" and $peers[.].idType == "interface")
    ' >/dev/null
}

check_fib() {
  local interfaces=$1
  shift
  "$@" | jq -e --argjson interfaces "$interfaces" '
    [.[] | select(.protocol == "bgp") | (.nexthops // [.])[] |
      select(.via.family == "inet6" and ((.via.host // "") | startswith("fe80:"))) | .dev
    ] | sort == ($interfaces | sort)
  ' >/dev/null
}

check_chassis() {
  local node_ip=$1 fixed_ip=$2 bridges=$3
  ip -j -4 address show dev lo | jq -e --arg ip "$node_ip" \
    'any(.[].addr_info[]; .local == $ip and .prefixlen == 32)' >/dev/null || return 1
  check_fib "$bridges" ip -j -4 route show table 10 exact 0.0.0.0/0 || return 1
  ip -j -4 route get fibmatch "$probe" from "$node_ip" |
    jq -e '.[0].dst == "default" and .[0].protocol == "bgp"' >/dev/null || return 1
  if [[ $check == withdrawn && $withdraw_ip == "$fixed_ip" ]]; then
    ip -j -4 route show table 42 exact "$fixed_ip/32" |
      jq -e 'length == 0' >/dev/null
  else
    ip -j -4 route show table 42 exact "$fixed_ip/32" |
      jq -e 'any(.[]; .protocol == "ovn")' >/dev/null
  fi
}

check_routes() {
  local spine_interfaces=$1 leaf index
  shift
  for index in "${chassis_indices[@]}"; do
    check_fib "$spine_interfaces" docker exec "$spine" ip -j -4 route show exact "${node_ips[index]}/32" || return 1
    for leaf in "$@"; do
      check_fib "[\"${node_ports[index]}\"]" docker exec "$leaf" ip -j -4 route show exact "${node_ips[index]}/32" || return 1
    done
    if [[ $check == withdrawn && $withdraw_ip == "${fixed_ips[index]}" ]]; then
      for leaf in "$@" "$spine"; do
        docker exec "$leaf" ip -j -4 route show exact "$withdraw_ip/32" |
          jq -e 'length == 0' >/dev/null || return 1
      done
    else
      check_fib "$spine_interfaces" docker exec "$spine" ip -j -4 route show exact "${fixed_ips[index]}/32" || return 1
      for leaf in "$@"; do
        check_fib "[\"${node_ports[index]}\"]" docker exec "$leaf" ip -j -4 route show exact "${fixed_ips[index]}/32" || return 1
      done
    fi
  done
}

wait_for_routes() {
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if check_routes "$@"; then return 0; fi
    sleep 2
  done
  docker exec "$spine" vtysh -c "show bgp ipv4 unicast" >&2
  return 1
}

wait_for_dual_tor() {
  wait_for_routes '["eth1","eth2"]' "${leaves[@]}"
}

check_traffic() {
  local index
  for index in "${chassis_indices[@]}"; do
    docker exec "$spine" ping -I "$probe" -c 3 -W 2 "${node_ips[index]}" || return 1
    docker exec "$spine" ping -I "$probe" -c 3 -W 2 "${fixed_ips[index]}" || return 1
  done
}

wait_for_traffic() {
  local attempt
  for ((attempt = 0; attempt < 15; attempt++)); do
    if check_traffic; then return 0; fi
    sleep 2
  done
  return 1
}

set_chassis_links() {
  local leaf=$1 action=$2 port
  for port in "${node_ports[@]}"; do
    docker exec "$leaf" ip link set "$port" "$action" || return 1
  done
}

if [[ $check == chassis ]]; then
  case "$(hostname -s)" in
    infra-lab-openstack) chassis_index=0 ;;
    infra-lab-openstack-compute) chassis_index=1 ;;
    *) echo 'Run chassis verification on an OpenStack lab VM.' >&2; exit 2 ;;
  esac
  check_chassis "${node_ips[chassis_index]}" "${fixed_ips[chassis_index]}" '["br-bgp-0","br-bgp-1"]'
  printf 'Chassis %s has an IPv4 default via both IPv6 link-local next hops and a local OVN host route for %s\n' \
    "${node_ips[chassis_index]}" "${fixed_ips[chassis_index]}"
  exit 0
fi

withdraw_ip=${2:-${fixed_ips[0]}}
if [[ $check == withdrawn && $withdraw_ip != "${fixed_ips[0]}" && $withdraw_ip != "${fixed_ips[1]}" ]]; then
  printf 'Unknown lab VM IP: %s\n' "$withdraw_ip" >&2
  exit 2
fi

if [[ $(hostname -s) != infra-lab-switches ]]; then
  echo 'Run fabric verification on infra-lab-switches.' >&2
  exit 2
fi

chassis_indices=(0 1)
if [[ $check != withdrawn ]]; then
  case "${2:-}" in
    "") ;;
    controller) chassis_indices=(0) ;;
    compute) chassis_indices=(1) ;;
    *) echo 'Expected controller or compute.' >&2; exit 2 ;;
  esac
fi
leaf_ports='["eth2"]'
for index in "${chassis_indices[@]}"; do
  leaf_ports=$(jq --arg port "${node_ports[index]}" '. + [$port]' <<<"$leaf_ports")
done

wait_for_dual_tor
check_peers "$spine" '["eth1","eth2"]'
for leaf in "${leaves[@]}"; do
  check_peers "$leaf" "$leaf_ports"
done

case "$check" in
  advertised)
    printf 'Selected VM fixed IPs advertised from their owning chassis on both ToRs\n'
    ;;
  withdrawn)
    printf 'VM fixed IP %s/32 withdrawn on both ToRs\n' "$withdraw_ip"
    ;;
  reachable)
    check_traffic
    ;;
  failover|failover-routes)
    trap 'for restore_leaf in "${leaves[@]}"; do set_chassis_links "$restore_leaf" up || true; done' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for leaf in "${leaves[@]}"; do
      set_chassis_links "$leaf" down
      if [[ $leaf == "${leaves[0]}" ]]; then
        wait_for_routes '["eth2"]' "${leaves[1]}"
      else
        wait_for_routes '["eth1"]' "${leaves[0]}"
      fi
      if [[ $check == failover ]]; then wait_for_traffic; fi
      set_chassis_links "$leaf" up
      wait_for_dual_tor
      if [[ $check == failover ]]; then wait_for_traffic; fi
    done
    trap - EXIT INT TERM
    printf 'Selected VM fixed IPs converged through each surviving ToR (%s)\n' "$check"
    ;;
esac
