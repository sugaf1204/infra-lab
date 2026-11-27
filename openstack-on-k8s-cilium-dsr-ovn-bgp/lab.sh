#!/usr/bin/env bash
# ファブリック・Kind・Cilium の起動と撤去。OpenStack は openstack.sh で扱う。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

lab=osk-bgp
# 他のラボと共有しない専用の kubeconfig と Docker ネットワークを使う。
export KUBECONFIG=$PWD/$lab.kubeconfig
export KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-$lab

render() {
  ansible-playbook -i localhost, -c local render.yml -e "lab_dir=$PWD"
}

case "${1:-}" in
  up)
    render
    docker network inspect "$KIND_EXPERIMENTAL_DOCKER_NETWORK" >/dev/null 2>&1 ||
      docker network create --subnet 172.20.24.0/24 "$KIND_EXPERIMENTAL_DOCKER_NETWORK"
    if ! kind get clusters | grep -Fxq "$lab"; then
      kind create cluster --config rendered/cluster.yaml --kubeconfig "$KUBECONFIG"
    fi
    containerlab deploy --topo rendered/topology.clab.yml --reconfigure
    nat_pid=$(docker inspect --format '{{.State.Pid}}' "clab-$lab-nat")
    nsenter --target "$nat_pid" --net iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null ||
      nsenter --target "$nat_pid" --net iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
      --version 1.21.0-pre.4 --namespace kube-system --values cilium-values.yaml --wait --timeout 15m
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
    until kubectl get crd ciliumbgpclusterconfigs.cilium.io ciliumloadbalancerippools.cilium.io ciliumbgpnodeconfigoverrides.cilium.io >/dev/null 2>&1; do
      sleep 2
    done
    # 各ノードの CiliumBGPNodeConfigOverride（送信元 127.0.0.2）を生成して適用する。
    kubectl get nodes -o name | sed 's|node/||' | while read -r node; do
      printf -- '---\napiVersion: cilium.io/v2\nkind: CiliumBGPNodeConfigOverride\nmetadata: {name: %s}\nspec: {bgpInstances: [{name: host-frr, peers: [{name: host-frr, localAddress: 127.0.0.2}]}]}\n' "$node"
    done | kubectl apply -f -
    kubectl apply -f bgp.yaml
    ;;
  workloads)
    # OpenStack と VM の作成後に実行する。VIP 10.240.250.10/.20/.30/.31 のバックエンドを登録する。
    kubectl apply -f pod-probe.yaml -f l7lb.yaml
    ./vm-backend.sh apply
    ;;
  render)
    render
    ;;
  down)
    containerlab destroy --topo rendered/topology.clab.yml --cleanup || true
    kind delete cluster --name "$lab" --kubeconfig "$KUBECONFIG" || true
    docker network rm "$KIND_EXPERIMENTAL_DOCKER_NETWORK" || true
    ;;
  *)
    echo "Usage: $0 {up|workloads|render|down}" >&2
    exit 2
    ;;
esac
