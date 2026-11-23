#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ovn_nics() {
  for i in 1 2; do
    ../common/tor-nic.sh "$1" "ovn-ctl-tor$i" "clab-full-l3-ip-clos-leaf$i" eth7 || true
    ../common/tor-nic.sh "$1" "ovn-tor$i" "clab-full-l3-ip-clos-leaf$i" eth8 || true
  done
}

case "${1:-}" in
  up)
    ansible-playbook -i localhost, -c local ../common/render-fabric.yml -e "lab_dir=$PWD"
    ovn_nics detach
    containerlab deploy --topo topology.clab.yml --reconfigure
    ovn_nics attach
    nat_pid=$(docker inspect --format '{{.State.Pid}}' clab-full-l3-ip-clos-nat)
    nsenter --target "$nat_pid" --net iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null ||
      nsenter --target "$nat_pid" --net iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    ;;
  down)
    ovn_nics detach
    containerlab destroy --topo topology.clab.yml --cleanup || true
    ;;
  *)
    echo "Usage: $0 {up|down}" >&2
    exit 2
    ;;
esac
