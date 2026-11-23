#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID != 0 || $# != 4 ]]; then
  echo "Usage: sudo $0 {attach|detach} HOST_NIC CONTAINER CONTAINER_PORT" >&2
  exit 2
fi

action=$1
nic=$2
container=$3
port=$4
if [[ ! $nic =~ ^(ovn|ovn-ctl)-tor[12]$ ||
      ! $container =~ ^clab-full-l3-ip-clos-leaf[12]$ ||
      ! $port =~ ^eth[56]$ ]]; then
  echo 'Expected a dedicated Leaf data port.' >&2
  exit 2
fi

pid=$(docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null || true)
if [[ ! $pid =~ ^[1-9][0-9]*$ ]]; then
  if [[ $action == detach ]]; then exit 0; fi
  echo "$container is not running." >&2
  exit 1
fi

in_tor() { nsenter --target "$pid" --net -- "$@"; }

alias_name="infra-lab:$nic"
owns_port() {
  in_tor ip -j link show dev "$port" 2>/dev/null |
    jq -e --arg alias "$alias_name" '.[0].ifalias == $alias' >/dev/null
}

case "$action" in
  attach)
    if ! owns_port; then
      if [[ ! -e /sys/class/net/$nic/device ]]; then
        echo "$nic: dedicated virtio NIC not found in the fabric namespace." >&2
        exit 1
      fi
      if in_tor ip link show dev "$port" >/dev/null 2>&1; then
        echo "$container:$port is already occupied." >&2
        exit 1
      fi
      ip link set dev "$nic" down alias "$alias_name"
      ip link set dev "$nic" netns "$pid" name "$port"
    fi
    in_tor sysctl -qw "net.ipv6.conf.$port.disable_ipv6=0" "net.ipv6.conf.$port.accept_ra_defrtr=0"
    in_tor ip link set dev "$port" up
    ;;
  detach)
    if owns_port; then
      in_tor ip link set dev "$port" down
      in_tor ip link set dev "$port" netns 1 name "$nic"
      ip link set dev "$nic" alias "" up
    fi
    ;;
  *) exit 2 ;;
esac
