#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

case "${1:-}" in
  up)
    ansible-playbook -i localhost, -c local ../common/render-fabric.yml -e "lab_dir=$PWD"
    if ! kind get clusters | grep -Fxq cilium-l3; then
      kind create cluster --config cluster.yaml
    fi
    containerlab deploy --topo topology.clab.yml --reconfigure
    kubectl label node cilium-l3-control-plane node.kubernetes.io/exclude-from-external-load-balancers- || true
    helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
      --version 1.21.0-pre.4 --namespace kube-system --values cilium-values.yaml --wait --timeout 10m
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
    kubectl wait --for=create --timeout=60s crd/ciliumbgpclusterconfigs.cilium.io crd/ciliumloadbalancerippools.cilium.io
    kubectl apply -f bgp.yaml -f probes.yaml
    ;;
  down)
    containerlab destroy --topo topology.clab.yml --cleanup || true
    kind delete cluster --name cilium-l3 || true
    ;;
  *)
    echo "Usage: $0 {up|down}" >&2
    exit 2
    ;;
esac
