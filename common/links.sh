#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $EUID != 0 || $(uname -s) != Linux || $# != 2 ]]; then
  echo "Usage: sudo $0 {attach|name} {fabric|k8s-control|k8s-fabric-control|k8s-worker|openstack|openstack-compute|openstack-fabric-controller|openstack-fabric-compute}" >&2
  exit 2
fi

case "$2" in
  fabric) vm=infra-lab-switches; prefix=k8s; mac_base=52:54:00:31:01 ;;
  k8s-control) vm=infra-lab-k8s-control; prefix=k8s-ctl; mac_base=52:54:00:31:05 ;;
  k8s-fabric-control) vm=infra-lab-switches; prefix=k8s-ctl; mac_base=52:54:00:31:03 ;;
  k8s-worker) vm=infra-lab-k8s-worker; prefix=k8s; mac_base=52:54:00:31:02 ;;
  openstack) vm=infra-lab-openstack; prefix=ovn-ctl; mac_base=52:54:00:32:05 ;;
  openstack-compute) vm=infra-lab-openstack-compute; prefix=ovn; mac_base=52:54:00:32:02 ;;
  openstack-fabric-controller) vm=infra-lab-switches; prefix=ovn-ctl; mac_base=52:54:00:32:03 ;;
  openstack-fabric-compute) vm=infra-lab-switches; prefix=ovn; mac_base=52:54:00:32:04 ;;
  *) exit 2 ;;
esac

# The fabric VM needs distinct names for its four ports. Each OpenStack
# chassis uses the same two names, independent of its libvirt networks.
name_prefix=$prefix
case "$2" in
  openstack) name_prefix=ovn ;;
  k8s-control) name_prefix=k8s ;;
esac

virsh() { command virsh -c qemu:///system "$@"; }

ensure_network() {
  local network=$1 bridge=$2
  if ! virsh net-info "$network" >/dev/null 2>&1; then
    virsh net-define /dev/stdin <<EOF
<network>
  <name>$network</name>
  <bridge name="$bridge" stp="off" delay="0"/>
</network>
EOF
  fi
  if ! virsh net-info "$network" | awk '/^Active:/ {exit ($2 != "yes")}'; then
    virsh net-start "$network"
  fi
  virsh net-autostart "$network"
}

attach_links() {
  exec 9>/run/lock/infra-lab-links.lock
  flock 9
  local index link mac network
  for index in 1 2; do
    link="$prefix-tor$index"
    mac="$mac_base:0$index"
    network="infra-lab-$link"
    ensure_network "$network" "il-$link"
    if ! virsh domiflist "$vm" --inactive | awk -v mac="$mac" '$5 == mac {found=1} END {exit !found}'; then
      virsh attach-interface "$vm" network "$network" --model virtio --mac "$mac" --config
    fi
    if [[ $(virsh domstate "$vm") == running ]] &&
      ! virsh domiflist "$vm" | awk -v mac="$mac" '$5 == mac {found=1} END {exit !found}'; then
      virsh attach-interface "$vm" network "$network" --model virtio --mac "$mac" --live
    fi
  done
}

name_links() {
  if [[ $(hostname -s) != "$vm" ]]; then
    echo "Run name on $vm." >&2
    exit 1
  fi
  local index link mac address_path device
  local links=()
  mkdir -p /etc/systemd/network
  for index in 1 2; do
    link="$name_prefix-tor$index"
    mac="$mac_base:0$index"
    device=
    for address_path in /sys/class/net/*/address; do
      [[ -e ${address_path%/address}/device ]] || continue
      if [[ $(< "$address_path") == "$mac" ]]; then
        device=${address_path%/address}
        device=${device##*/}
        break
      fi
    done
    if [[ -z $device ]]; then
      echo "$link ($mac): VM uplink is missing." >&2
      return 1
    fi
    cat > "/etc/systemd/network/10-infra-lab-$link.link" <<EOF
[Match]
MACAddress=$mac
[Link]
Name=$link
EOF
    if [[ $device != "$link" ]]; then
      ip link set "$device" down
      ip link set "$device" name "$link"
    fi
    if [[ $prefix != "$name_prefix" ]]; then
      rm -f "/etc/systemd/network/10-infra-lab-$prefix-tor$index.link" \
        "/etc/systemd/network/10-infra-lab-$prefix-tor$index.network"
    fi
    cat > "/etc/systemd/network/10-infra-lab-$link.network" <<EOF
[Match]
Name=$link
[Link]
RequiredForOnline=no
[Network]
KeepMaster=yes
DHCP=no
IPv6AcceptRA=no
LinkLocalAddressing=ipv6
EOF
    links+=("$link")
    ip link set "$link" up
  done
  if systemctl is-active --quiet systemd-networkd; then
    networkctl reload
    networkctl reconfigure "${links[@]}"
  fi
  for link in "${links[@]}"; do
    # Keep kernel neighbor discovery while excluding RA default routes.
    sysctl -qw "net.ipv6.conf.$link.accept_ra_defrtr=0" "net.ipv6.conf.$link.accept_ra=2"
  done
}

case "$1" in
  attach) attach_links ;;
  name) name_links ;;
  *) exit 2 ;;
esac
