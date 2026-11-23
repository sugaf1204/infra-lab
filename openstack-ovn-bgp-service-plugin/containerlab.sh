#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:$#" in
  deploy:1|configure:1|destroy:1) ;;
  *) echo "Usage: $0 {deploy|configure|destroy}" >&2; exit 2 ;;
esac

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
fabric_nics() {
  local action=$1 index leaf
  for index in 1 2; do
    leaf=clab-ovn-bgp-leaf$index
    ../common/tor-nic.sh "$action" "ovn-ctl-tor$index" "$leaf" eth1
    ../common/tor-nic.sh "$action" "ovn-tor$index" "$leaf" eth3
  done
}

current_host=$(hostname -s)
case "$current_host:$1" in
  infra-lab-switches:deploy)
    ansible-playbook -i localhost, -c local ../common/render-fabric.yml -e "lab_dir=$PWD"
    for port in ovn-ctl-tor1 ovn-ctl-tor2 ovn-tor1 ovn-tor2; do
      ip link show "$port" >/dev/null
    done
    containerlab deploy -t topology.clab.yml
    fabric_nics attach
    exit 0
    ;;
  infra-lab-switches:destroy)
    fabric_nics detach
    exec containerlab destroy --cleanup -t topology.clab.yml
    ;;
  infra-lab-openstack:configure|infra-lab-openstack-compute:configure)
    exec ansible-playbook -i localhost, -c local chassis.yml
    ;;
  infra-lab-openstack:destroy|infra-lab-openstack-compute:destroy)
    rm -f /etc/netplan/80-infra-lab-chassis.yaml /etc/sysctl.d/80-infra-lab-chassis.conf
    rm -f /etc/systemd/network/10-netplan-lo.network.d/80-infra-lab-policy.conf
    netplan apply
    systemctl disable --now frr
    exit 0
    ;;
  *)
    echo 'Deploy the fabric on infra-lab-switches and configure on each OpenStack chassis.' >&2
    exit 2
    ;;
esac
