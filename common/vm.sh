#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 || $(uname -s) != Linux ]]; then
  echo "libvirt ホストで sudo を使って実行してください。" >&2
  exit 1
fi

action=${1:-}
case "${2:-}" in
  fabric) name=infra-lab-switches; ram=1536; cpus=2; disk_size=16G; address=192.168.122.250; mac=52:54:00:33:00:01 ;;
  k8s-control) name=infra-lab-k8s-control; ram=5120; cpus=6; disk_size=80G; address=192.168.122.219; mac=52:54:00:33:00:02 ;;
  k8s-worker) name=infra-lab-k8s-worker; ram=3072; cpus=2; disk_size=40G; address=192.168.122.7; mac=52:54:00:33:00:03 ;;
  openstack) name=infra-lab-openstack; ram=12288; cpus=8; disk_size=120G; address=192.168.122.119; mac=52:54:00:33:00:04 ;;
  openstack-compute) name=infra-lab-openstack-compute; ram=4096; cpus=2; disk_size=60G; address=192.168.122.99; mac=52:54:00:33:00:05 ;;
  *) echo "Usage: $0 {create|start|resize} {fabric|k8s-control|k8s-worker|openstack|openstack-compute} [base-qcow2 ssh-public-key-file]" >&2; exit 2 ;;
esac
case "$action" in
  create) [[ $# == 4 ]] ;;
  start|resize) [[ $# == 2 ]] ;;
  *) exit 2 ;;
esac

export LC_ALL=C
virsh() { command virsh -c qemu:///system "$@"; }
exec 9>/run/lock/infra-lab-vm.lock
flock 9

check_capacity() {
  local active name_in_use allocated=0 limit total available
  local reserve=$((5 * 1024 * 1024))
  total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  active=$(virsh list --name)
  while IFS= read -r name_in_use; do
    [[ -n $name_in_use ]] || continue
    limit=$(virsh dominfo "$name_in_use" | awk '/^Max memory:/ {print $3}')
    [[ $limit =~ ^[0-9]+$ ]]
    allocated=$((allocated + limit))
  done <<<"$active"
  if (( allocated + ram * 1024 + reserve > total || ram * 1024 + reserve > available )); then
    echo "既存 VM の最大メモリとホストの 5 GiB を確保すると、$name の起動容量が不足します。" >&2
    return 1
  fi
}

if [[ $action == resize ]]; then
  if [[ $(virsh domstate "$name") != "shut off" ]]; then
    echo "$name を停止してから resize を実行してください。" >&2
    exit 1
  fi
  desired=$((ram * 1024))
  current_max=$(virsh dominfo "$name" | awk '/^Max memory:/ {print $3}')
  if (( desired < current_max )); then
    virsh setmem "$name" "$desired" --config
    virsh setmaxmem "$name" "$desired" --config
  else
    virsh setmaxmem "$name" "$desired" --config
    virsh setmem "$name" "$desired" --config
  fi
  exit 0
fi

if [[ $action == start ]]; then
  if [[ $(virsh domstate "$name") == running ]]; then
    exit 0
  fi
  check_capacity
  virsh start "$name"
  exit 0
fi

if virsh dominfo "$name" >/dev/null 2>&1; then
  echo "$name は定義済みです。起動には start を使ってください。" >&2
  exit 1
fi
check_capacity

base=$(realpath "$3")
ssh-keygen -lf "$4" >/dev/null
read -r key_type key_data _ < "$4"
[[ $key_type =~ ^[a-zA-Z0-9@._+-]+$ && $key_data =~ ^[a-zA-Z0-9+/=]+$ ]]
[[ $(qemu-img info --output=json "$base" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])') == qcow2 ]]
[[ $(virsh net-info default | awk '/^Active:/ {print $2}') == yes ]]

image_dir="/var/lib/libvirt/images/$name"
mkdir -m 0755 "$image_dir"
seed_config=
network_config=
cleanup() {
  if [[ -n $seed_config ]]; then
    rm -f "$seed_config"
  fi
  if [[ -n $network_config ]]; then
    rm -f "$network_config"
  fi
  if ! virsh dominfo "$name" >/dev/null 2>&1; then
    rm -f "$image_dir/root.qcow2" "$image_dir/seed.iso"
    rmdir "$image_dir"
  fi
}
trap cleanup EXIT

qemu-img convert -f qcow2 -O qcow2 "$base" "$image_dir/root.qcow2"
qemu-img resize "$image_dir/root.qcow2" "$disk_size"
seed_config=$(mktemp)
network_config=$(mktemp)
printf '#cloud-config\nhostname: %s\nssh_pwauth: false\nssh_authorized_keys:\n  - %s\n' "$name" "$key_type $key_data" > "$seed_config"
cat > "$network_config" <<EOF
version: 2
ethernets:
  management:
    match:
      macaddress: "$mac"
    addresses: [$address/24]
    dhcp4: false
    dhcp6: false
    accept-ra: false
EOF
cloud-localds --network-config="$network_config" "$image_dir/seed.iso" "$seed_config"
virt-install --connect qemu:///system --name "$name" --import \
  --virt-type kvm --cpu host-passthrough --vcpus "$cpus" --memory "$ram" \
  --os-variant ubuntu22.04 --boot uefi \
  --disk "path=$image_dir/root.qcow2,bus=virtio,format=qcow2" \
  --disk "path=$image_dir/seed.iso,device=cdrom,readonly=on" \
  --network "network=default,model=virtio,mac=$mac" --graphics none --noautoconsole
