#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${EUID}:$#" in
  static:0:2)
    case "$(hostname -s)" in
      infra-lab-fabric|infra-lab-k8s-control) address=192.168.122.219 ;;
      infra-lab-k8s-worker) address=192.168.122.7 ;;
      infra-lab-openstack) address=192.168.122.119 ;;
      infra-lab-openstack-compute) address=192.168.122.99 ;;
      infra-lab-switches) address=192.168.122.250 ;;
      *) echo 'Run on a lab VM.' >&2; exit 2 ;;
    esac
    interface=$2
    [[ $interface =~ ^[[:alnum:]_]+$ ]]
    ip link show dev "$interface" >/dev/null
    netplan set --origin-hint 60-infra-lab-static \
      "ethernets.$interface={dhcp4: false, dhcp6: false, accept-ra: false, addresses: [$address/24]}"
    netplan apply
    ;;
  disable-dhcp:0:1)
    export LC_ALL=C
    virsh() { command virsh -c qemu:///system "$@"; }
    domains=$(virsh list --all --name)
    while IFS= read -r domain; do
      [[ -n $domain ]] || continue
      interfaces=$(virsh domiflist --inactive "$domain")
      if ! awk '$2 == "network" && $3 == "default" {found = 1} END {exit !found}' <<<"$interfaces"; then
        continue
      fi
      case "$domain" in
        infra-lab-fabric|infra-lab-switches|infra-lab-k8s-control|infra-lab-k8s-worker|infra-lab-openstack|infra-lab-openstack-compute) ;;
        *) echo "$domain also uses the default network." >&2; exit 1 ;;
      esac
    done <<<"$domains"
    for mode in config live; do
      flags=()
      if [[ $mode == config ]]; then flags=(--inactive); fi
      xml=$(virsh net-dumpxml default "${flags[@]}")
      ranges=$(python3 -c 'import sys, xml.etree.ElementTree as ET
for entry in ET.parse(sys.stdin).findall("./ip/dhcp/*"):
    if entry.tag not in ("range", "host"):
        sys.exit("Unexpected DHCP configuration")
    print(entry.tag + "|" + ET.tostring(entry, encoding="unicode").strip())' <<<"$xml")
      while IFS='|' read -r kind entry; do
        [[ -n $kind ]] || continue
        virsh net-update default delete "ip-dhcp-$kind" "$entry" "--$mode"
      done <<<"$ranges"
    done
    ;;
  *) echo "Usage: sudo $0 {static INTERFACE|disable-dhcp}" >&2; exit 2 ;;
esac
