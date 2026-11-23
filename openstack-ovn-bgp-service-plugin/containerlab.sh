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
  infra-lab-fabric:deploy)
    for port in ovn-ctl-tor1 ovn-ctl-tor2 ovn-tor1 ovn-tor2; do
      ip link show "$port" >/dev/null
    done
    containerlab deploy -t topology.clab.yml
    fabric_nics attach
    exit 0
    ;;
  infra-lab-fabric:destroy)
    fabric_nics detach
    exec containerlab destroy --cleanup -t topology.clab.yml
    ;;
  infra-lab-openstack:configure|infra-lab-openstack:destroy)
    node_ip=203.0.113.31/32
    uplinks=(ovn-ctl-tor1 ovn-ctl-tor2)
    frr_config=frr/chassis.conf
    ;;
  infra-lab-openstack-compute:configure|infra-lab-openstack-compute:destroy)
    node_ip=203.0.113.32/32
    uplinks=(ovn-tor1 ovn-tor2)
    frr_config=frr/compute.conf
    ;;
  *)
    echo 'Deploy the fabric on infra-lab-fabric and configure on each OpenStack chassis.' >&2
    exit 2
    ;;
esac

bridges=(br-bgp-0 br-bgp-1)

if [[ $1 == destroy ]]; then
  for index in "${!uplinks[@]}"; do
    ovs-vsctl --if-exists del-port "${bridges[index]}" "${uplinks[index]}"
  done
  ip -4 rule del pref 10111 from "$node_ip" unreachable 2>/dev/null || true
  ip -4 rule del pref 10110 from "$node_ip" lookup 10 2>/dev/null || true
  ip -4 address del "$node_ip" dev lo 2>/dev/null || true
  exit 0
fi

for uplink in "${uplinks[@]}"; do ip link show "$uplink" >/dev/null; done
ip -4 address replace "$node_ip" dev lo
ovs-vsctl --may-exist add-br br-ex
ip link set br-ex up
for index in "${!uplinks[@]}"; do
  bridge=${bridges[index]}
  uplink=${uplinks[index]}
  ovs-vsctl --may-exist add-br "$bridge" -- --may-exist add-port "$bridge" "$uplink"
  sysctl -q -w "net.ipv6.conf.$bridge.accept_ra_defrtr=0" "net.ipv6.conf.$uplink.accept_ra_defrtr=0"
  ip link set "$bridge" up
  ip link set "$uplink" up
done

# The flat tenant network must map public to br-ex on every chassis.
mapping=$(ovs-vsctl --if-exists get Open_vSwitch . external_ids:ovn-bridge-mappings | tr -d '"')
if [[ ,$mapping, != *,public:br-ex,* ]]; then
  ovs-vsctl set Open_vSwitch . external_ids:ovn-bridge-mappings="${mapping:+$mapping,}public:br-ex"
fi
# Let the OVN agent reconcile the BGP bridge mapping and chassis metadata together.
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
install -o frr -g frr -m 640 "$frr_config" /etc/frr/frr.conf
systemctl restart frr
