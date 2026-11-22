#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$EUID" != 0 ]]; then
  echo 'Run this lab as root on the Linux lab host.' >&2
  exit 1
fi

action="${1:-}"
case "$action" in
  up|verify|down) ;;
  *)
    echo "Usage: $0 {up|verify|down}" >&2
    exit 2 ;;
esac

for cmd in docker kind containerlab flock kubectl; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
if [[ "$action" == up ]] && ! command -v helm >/dev/null; then
  echo 'Missing command: helm' >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077
mkdir -p .lab-state
exec 9>.lab-state/lock
flock 9

cluster=cilium-l3
control=$cluster-control-plane
worker=$cluster-worker
tor1=clab-$cluster-tor1
tor2=clab-$cluster-tor2
client=clab-$cluster-client
export KUBECONFIG="$PWD/.lab-state/kubeconfig"
export KIND_EXPERIMENTAL_PROVIDER=docker CLAB_RUNTIME=docker
export DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT

configure_node() {
  local node=$1 address=$2 gateway=$3
  docker exec "$node" ip -4 addr replace "$address" dev eth1
  docker exec "$node" ip -4 route replace 10.220.0.0/20 via "$gateway" dev eth1
  docker exec "$node" ip -4 route replace 10.220.240.12/30 via "$gateway" dev eth1
}

up() {
  if [[ ! -f .lab-state/owned ]]; then
    local clusters
    clusters=$(kind get clusters)
    if grep -Fxq "$cluster" <<<"$clusters" ||
       docker container inspect "$tor1" >/dev/null 2>&1 ||
       docker container inspect "$tor2" >/dev/null 2>&1 ||
       docker container inspect "$client" >/dev/null 2>&1; then
      echo "An existing cluster or topology uses the $cluster name." >&2
      return 1
    fi
    touch .lab-state/owned
  fi
  if [[ ! -s "$KUBECONFIG" ]]; then
    kind create cluster --name "$cluster" --config kind.yaml --kubeconfig "$KUBECONFIG" \
      --image kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a
  fi

  if [[ ! -f .lab-state/topology-ready ]]; then
    if [[ -f .lab-state/topology-started ]]; then
      echo "Earlier topology deployment was incomplete. Run '$0 down' before retrying." >&2
      return 1
    fi
    touch .lab-state/topology-started
    containerlab deploy --topo topology.clab.yml
    touch .lab-state/topology-ready
  fi
  configure_node "$control" 10.220.240.2/30 10.220.240.1
  configure_node "$worker" 10.220.240.6/30 10.220.240.5

  helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
    --version 1.18.17 --namespace kube-system --values cilium-values.yaml --wait --timeout 10m
  local crds=(
    crd/ciliumbgpadvertisements.cilium.io
    crd/ciliumbgpclusterconfigs.cilium.io
    crd/ciliumbgppeerconfigs.cilium.io
    crd/ciliumloadbalancerippools.cilium.io
  )
  kubectl wait --for=create --timeout=120s "${crds[@]}"
  kubectl wait --for=condition=Established --timeout=120s "${crds[@]}"
  kubectl apply -f bgp.yaml -f probes.yaml
  verify
}

verify() {
  local control_pod worker_pod control_cidr worker_cidr vip=10.220.250.10
  kubectl -n lab-probe wait --for=condition=Ready --timeout=180s pod/probe-control pod/probe-worker
  kubectl -n lab-probe wait --timeout=120s \
    --for="jsonpath={.status.loadBalancer.ingress[0].ip}=$vip" service/probe-worker
  control_pod=$(kubectl -n lab-probe get pod probe-control -o 'jsonpath={.status.podIP}')
  worker_pod=$(kubectl -n lab-probe get pod probe-worker -o 'jsonpath={.status.podIP}')
  control_cidr=$(kubectl get node "$control" -o 'jsonpath={.spec.podCIDR}')
  worker_cidr=$(kubectl get node "$worker" -o 'jsonpath={.spec.podCIDR}')
  local deadline=$((SECONDS + 90))
  until docker exec "$tor1" ip -4 route show exact "$control_cidr" | grep -F 'via 10.220.240.2 dev eth1' >/dev/null &&
        docker exec "$tor1" ip -4 route show exact "$worker_cidr" | grep -F 'via 10.220.240.10 dev eth2' >/dev/null &&
        docker exec "$tor2" ip -4 route show exact "$worker_cidr" | grep -F 'via 10.220.240.6 dev eth1' >/dev/null &&
        docker exec "$tor2" ip -4 route show exact "$control_cidr" | grep -F 'via 10.220.240.9 dev eth2' >/dev/null &&
        docker exec "$tor1" ip -4 route show exact "$vip/32" | grep -F 'via 10.220.240.10 dev eth2' >/dev/null &&
        docker exec "$tor2" ip -4 route show exact "$vip/32" | grep -F 'via 10.220.240.6 dev eth1' >/dev/null; do
    if (( SECONDS >= deadline )); then
      docker exec "$tor1" vtysh -c 'show bgp ipv4 unicast summary'
      docker exec "$tor2" vtysh -c 'show bgp ipv4 unicast summary'
      return 1
    fi
    sleep 2
  done

  docker exec "$control" ip -4 route get "$worker_pod" | grep -F 'via 10.220.240.1 dev eth1'
  docker exec "$worker" ip -4 route get "$control_pod" | grep -F 'via 10.220.240.5 dev eth1'
  kubectl -n lab-probe exec probe-control -- ping -c 2 -W 2 "$worker_pod"
  kubectl -n lab-probe exec probe-worker -- ping -c 2 -W 2 "$control_pod"
  docker exec "$client" ping -c 2 -W 2 "$control_pod"
  docker exec "$client" ping -c 2 -W 2 "$worker_pod"
  docker exec "$client" wget -q -T 5 -O - "http://$vip/" | grep -Fx 'probe-worker'
}

down() {
  if [[ ! -f .lab-state/owned ]]; then
    return
  fi
  if [[ -f .lab-state/topology-started ]]; then
    containerlab destroy --topo topology.clab.yml --cleanup
    rm -f .lab-state/topology-started .lab-state/topology-ready
  fi
  kind delete cluster --name "$cluster" --kubeconfig "$KUBECONFIG"
  rm -f "$KUBECONFIG" .lab-state/owned
}

"$action"
