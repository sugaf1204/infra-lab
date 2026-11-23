#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:$#" in
  deploy:1|configure:1|destroy:1) ;;
  *) echo "Usage: $0 {deploy|configure|destroy}" >&2; exit 2 ;;
esac

current_host=$(hostname -s)
case "$current_host" in
  infra-lab-openstack)
    node_ip=203.0.113.31/32
    uplinks=(ovnbgp-uplink ovnbgp-uplink1)
    remote_links=(ovn-tor1 ovn-tor2)
    remote_bridges=(clab-ovn-tor1 clab-ovn-tor2)
    frr_config=frr/chassis.conf
    ;;
  infra-lab-openstack-compute)
    node_ip=203.0.113.32/32
    uplinks=(ovn-tor1 ovn-tor2)
    frr_config=frr/compute.conf
    if [[ $1 == deploy ]]; then
      echo 'Deploy the fabric on infra-lab-openstack; run configure on compute.' >&2
      exit 2
    fi
    ;;
  *)
    printf 'Run on an OpenStack lab VM. Current host is %s.\n' "$current_host" >&2
    exit 1
    ;;
esac

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
bridges=(br-bgp-0 br-bgp-1)

if [[ $1 == destroy ]]; then
  for index in "${!uplinks[@]}"; do
    ovs-vsctl --if-exists del-port "${bridges[index]}" "${uplinks[index]}"
  done
  ip -4 rule del pref 10111 from "$node_ip" unreachable 2>/dev/null || true
  ip -4 rule del pref 10110 from "$node_ip" lookup 10 2>/dev/null || true
  ip -4 address del "$node_ip" dev lo 2>/dev/null || true
  if [[ $current_host == infra-lab-openstack ]]; then
    containerlab destroy --cleanup -t topology.clab.yml
    for bridge in "${remote_bridges[@]}"; do
      if ip link show "$bridge" >/dev/null 2>&1; then
        ip link del "$bridge" type bridge
      fi
    done
  fi
  exit 0
fi

if [[ $current_host == infra-lab-openstack ]]; then
  for index in "${!remote_links[@]}"; do
    bridge=${remote_bridges[index]}
    uplink=${remote_links[index]}
    ip link show "$uplink" >/dev/null
    if ! ip link show "$bridge" >/dev/null 2>&1; then
      ip link add "$bridge" type bridge
    fi
    # These point-to-point bridges must forward IPv6 neighbor discovery.
    ip link set dev "$bridge" type bridge mcast_snooping 0
    sysctl -q -w "net.ipv6.conf.$bridge.disable_ipv6=1" "net.ipv6.conf.$uplink.disable_ipv6=1"
    ip link set "$uplink" master "$bridge"
    ip link set "$uplink" up
    ip link set "$bridge" up
  done
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
