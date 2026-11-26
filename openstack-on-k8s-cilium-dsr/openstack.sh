#!/usr/bin/env bash
# OpenStack-Helm 2026.2 を osk8s クラスタへ導入する。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG=$PWD/osk8s.kubeconfig
ns=openstack
repo=https://tarballs.opendev.org/openstack/openstack-helm

install() { # <release> <timeout> <values...>
  local chart=$1 timeout=$2; shift 2
  local args=()
  for v in "$@"; do args+=(--values "openstack/$v.yaml"); done
  # helm --wait は使わない。インストール後フックのジョブを待つ Pod があり、--wait だとデッドロックする。
  helm upgrade --install "$chart" "$chart" --repo "$repo" --version "~2026.2.0" \
    --namespace "$ns" "${args[@]}"
  wait_pods "$timeout"
}

wait_pods() { # 全 Pod が Ready または Succeeded になるまで待つ
  local deadline=$((SECONDS + ${1%m} * 60))
  while ((SECONDS < deadline)); do
    sleep 10
    if ! kubectl -n "$ns" get pods -o json | jq -e '
      [.items[] | select(.status.phase != "Succeeded") |
        select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0)] | length > 0
    ' >/dev/null; then return 0; fi
  done
  kubectl -n "$ns" get pods | grep -vE "Running|Completed" >&2
  return 1
}

case "${1:-}" in
  prepare)
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label --overwrite node -l infra-lab/group=os-controller \
      openstack-control-plane=enabled openstack-network-node=enabled
    kubectl label --overwrite node -l infra-lab/group=os-compute \
      openstack-compute-node=enabled openvswitch=enabled
    # compute は NIC を OVS に収容した後、ループバック以外の宛先（Pod IP）がホストに届かない。
    # hostNetwork の DaemonSet だけを置く。
    kubectl taint --overwrite node -l infra-lab/group=os-compute infra-lab/group=os-compute:NoSchedule
    kubectl apply -f cilium-compute.yaml
    ;;
  infra)
    install rabbitmq 15m infra
    install mariadb 15m infra
    install memcached 10m infra
    ;;
  control)
    install keystone 20m keystone
    install glance 20m glance
    ;;
  network)
    install openvswitch 15m openvswitch
    install ovn 15m ovn
    kubectl apply -f openstack/chassis-prep.yaml
    ;;
  compute)
    # libvirt と nova-compute は neutron の ovn-agent 起動を待つため --wait を外して並行に進める
    helm upgrade --install libvirt libvirt --repo "$repo" --version "~2026.2.0" -n "$ns" --values openstack/libvirt.yaml
    helm upgrade --install placement placement --repo "$repo" --version "~2026.2.0" -n "$ns" --values openstack/placement.yaml
    helm upgrade --install nova nova --repo "$repo" --version "~2026.2.0" -n "$ns" --values openstack/nova.yaml
    install neutron 40m neutron
    ;;
  *)
    echo "Usage: $0 {prepare|infra|control|network|compute}" >&2
    exit 2
    ;;
esac
