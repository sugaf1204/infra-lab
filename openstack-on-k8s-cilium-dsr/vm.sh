#!/usr/bin/env bash
# tenant の flat network と、L4LB のバックエンドになる VM（compute ごとに 1 台）を作る。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG=$PWD/osk8s.kubeconfig
os() { kubectl -n openstack exec deploy/openstack-client -- openstack "$@"; }
image_url=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

case "${1:-}" in
  up)
    if ! os image show ubuntu-cloud >/dev/null 2>&1; then
      kubectl -n openstack exec deploy/openstack-client -- sh -c "curl -fsSL -o /tmp/noble.img $image_url"
      os image create --public --disk-format qcow2 --container-format bare --file /tmp/noble.img ubuntu-cloud
    fi
    os flavor show lab >/dev/null 2>&1 || os flavor create --vcpus 1 --ram 1024 --disk 5 lab
    os network show tenant-flat >/dev/null 2>&1 ||
      os network create --provider-network-type flat --provider-physical-network public tenant-flat
    os subnet show tenant-flat-v4 >/dev/null 2>&1 ||
      os subnet create --network tenant-flat --subnet-range 10.240.0.0/24 --gateway 10.240.0.1 --dhcp tenant-flat-v4
    if ! os security group show lab-dsr >/dev/null 2>&1; then
      # DSR の終端と戻りの書き換えは compute の Cilium が行うので、OVN から見た通信は
      # 「クライアント IP ↔ VM 固定 IP」の対称な TCP になる。通常のステートフルな SG でよい。
      os security group create lab-dsr
      os security group rule create --ingress --protocol icmp lab-dsr
      os security group rule create --ingress --protocol tcp --dst-port 80 lab-dsr
      os security group rule create --ingress --protocol tcp --dst-port 22 lab-dsr
    fi
    kubectl -n openstack exec -i deploy/openstack-client -- sh -c "cat > /tmp/user-data" \
      < openstack/vm-user-data.yaml
    i=0
    for host in $(os compute service list --service nova-compute -f value -c Host | sort); do
      i=$((i + 1)); ip=10.240.0.2$i
      if ! os port show "vm$i" >/dev/null 2>&1; then
        os port create --network tenant-flat --fixed-ip "subnet=tenant-flat-v4,ip-address=$ip" \
          --security-group lab-dsr "vm$i"
      fi
      os server show "vm$i" >/dev/null 2>&1 ||
        os server create --flavor lab --image ubuntu-cloud --port "vm$i" --config-drive true \
          --user-data /tmp/user-data --availability-zone "nova:$host" "vm$i"
    done
    os server list
    ;;
  down)
    for s in $(os server list -f value -c Name); do os server delete --wait "$s"; done
    for p in $(os port list --network tenant-flat -f value -c Name | grep '^vm' || true); do os port delete "$p"; done
    os security group delete lab-dsr || true
    os subnet delete tenant-flat-v4 || true
    os network delete tenant-flat || true
    ;;
  *)
    echo "Usage: $0 {up|down}" >&2
    exit 2
    ;;
esac
