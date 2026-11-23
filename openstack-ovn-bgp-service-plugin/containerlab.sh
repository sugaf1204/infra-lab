#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:$#" in
  deploy:1|configure:1|destroy:1) ;;
  *) echo "Usage: $0 {deploy|configure|destroy}" >&2; exit 2 ;;
esac

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
current_host=$(hostname -s)
case "$current_host:$1" in
  infra-lab-switches:deploy)
    exec ../full-l3-ip-clos/lab.sh up
    ;;
  infra-lab-switches:destroy)
    exec ../full-l3-ip-clos/lab.sh down
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
    echo 'Deploy the shared fabric on infra-lab-switches and configure on each OpenStack chassis.' >&2
    exit 2
    ;;
esac
