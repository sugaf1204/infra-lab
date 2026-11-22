#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:$#" in
  deploy:1|configure:1|destroy:1) ;;
  *) echo "Usage: $0 {deploy|configure|destroy}" >&2; exit 2 ;;
esac

chassis=infra-lab-openstack
current_host=$(hostname -s)
if [[ $current_host != "$chassis" ]]; then
  printf 'Run this command on the %s VM. Current host is %s.\n' \
    "$chassis" "$current_host" >&2
  exit 1
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
node_ip=203.0.113.31/32
uplinks=(ovnbgp-uplink ovnbgp-uplink1)
bridges=(br-bgp-0 br-bgp-1)

if [[ $1 == destroy ]]; then
  for index in "${!uplinks[@]}"; do
    ovs-vsctl --if-exists del-port "${bridges[index]}" "${uplinks[index]}"
  done
  ip -4 rule del pref 10111 from "$node_ip" unreachable 2>/dev/null || true
  ip -4 rule del pref 10110 from "$node_ip" lookup 10 2>/dev/null || true
  ip -4 address del "$node_ip" dev lo 2>/dev/null || true
  exec containerlab destroy --cleanup -t topology.clab.yml
fi

if [[ $1 == deploy ]]; then
  containerlab deploy -t topology.clab.yml
fi
ip -4 address replace "$node_ip" dev lo
ovs-vsctl --may-exist add-br br-ex
ip link set br-ex up
for index in "${!uplinks[@]}"; do
  bridge=${bridges[index]}
  uplink=${uplinks[index]}
  ovs-vsctl --may-exist add-br "$bridge" -- --may-exist add-port "$bridge" "$uplink"
  ip link set "$bridge" up
  ip link set "$uplink" up
done

# Let the OVN agent reconcile the bridge mapping and chassis metadata together.
ovs-vsctl set Open_vSwitch . \
  external_ids:neutron-bgp-peer-bridges=br-bgp-0,br-bgp-1 \
  external_ids:neutron-bgp-interconnect-bridge=br-ex
systemctl restart devstack@q-ovn-agent.service

if [[ -z $(ip -4 rule show pref 10110) ]]; then
  ip -4 rule add pref 10110 from "$node_ip" lookup 10
fi
if [[ -z $(ip -4 rule show pref 10111) ]]; then
  ip -4 rule add pref 10111 from "$node_ip" unreachable
fi
sed -i 's/^bgpd=no$/bgpd=yes/' /etc/frr/daemons
install -o frr -g frr -m 640 frr/chassis.conf /etc/frr/frr.conf
systemctl restart frr
