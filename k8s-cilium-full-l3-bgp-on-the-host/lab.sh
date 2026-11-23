#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

case "${1:-}" in
  up)
    if ! kind get clusters | grep -Fxq cilium-l3; then
      kind create cluster --config cluster.yaml
    fi
    ../full-l3-ip-clos/lab.sh up
    kubectl label node cilium-l3-control-plane node.kubernetes.io/exclude-from-external-load-balancers- || true
    helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
      --version 1.21.0-pre.4 --namespace kube-system --values cilium-values.yaml --wait --timeout 10m
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
    until kubectl get crd ciliumbgpclusterconfigs.cilium.io ciliumloadbalancerippools.cilium.io >/dev/null 2>&1; do
      sleep 2
    done
    kubectl apply -f bgp.yaml -f probes.yaml
    ;;
  down)
    kind delete cluster --name cilium-l3 || true
    ;;
  *)
    echo "Usage: $0 {up|down}" >&2
    exit 2
    ;;
esac
