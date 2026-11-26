#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG=$PWD/osk8s.kubeconfig

case "${1:-}" in
  up)
    if ! kind get clusters | grep -Fxq osk8s; then
      kind create cluster --config cluster.yaml --kubeconfig "$KUBECONFIG"
    fi
    ansible-playbook -i localhost, -c local ../common/render-fabric.yml -e "lab_dir=$PWD"
    containerlab deploy --topo topology.clab.yml --reconfigure
    nat_pid=$(docker inspect --format '{{.State.Pid}}' clab-osk8s-nat)
    nsenter --target "$nat_pid" --net iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null ||
      nsenter --target "$nat_pid" --net iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
      --version 1.20.5 --namespace kube-system --values cilium-values.yaml --wait --timeout 15m
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
    until kubectl get crd ciliumbgpclusterconfigs.cilium.io ciliumloadbalancerippools.cilium.io >/dev/null 2>&1; do
      sleep 2
    done
    kubectl apply -f bgp.yaml
    ;;
  down)
    containerlab destroy --topo topology.clab.yml --cleanup || true
    kind delete cluster --name osk8s || true
    ;;
  *)
    echo "Usage: $0 {up|down}" >&2
    exit 2
    ;;
esac
