#!/usr/bin/env bash
# VM の固定 IP を L4LB の Service バックエンドとして登録する。
#  - セレクタなし Service + EndpointSlice: VIP → VM IP の振り分け先
#  - CiliumEndpoint: VM IP → compute ノードの対応（Geneve DSR のトンネル終端先）を全ノードの ipcache に配る
# 実運用では Neutron のポート情報からこの 2 つを同期するコントローラーに相当する。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG=$PWD/osk-bgp.kubeconfig

vip=10.240.250.20
# name compute-node fixed-ip
vms=(
  "vm1 osk-bgp-worker5 10.250.0.11"
  "vm2 osk-bgp-worker6 10.250.0.12"
)

{
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata: {name: lab-vm}
---
apiVersion: v1
kind: Service
metadata:
  name: vm-web
  namespace: lab-vm
  labels: {lab.infra/l4lb: "true"}
  annotations: {lbipam.cilium.io/ips: $vip}
spec:
  type: LoadBalancer
  ports:
    - {name: http, port: 80, targetPort: 80, protocol: TCP}
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: vm-web-vms
  namespace: lab-vm
  labels: {kubernetes.io/service-name: vm-web}
addressType: IPv4
ports:
  - {name: http, port: 80, protocol: TCP}
endpoints:
YAML
  for vm in "${vms[@]}"; do
    read -r name node ip <<< "$vm"
    printf '  - {addresses: ["%s"], nodeName: %s, conditions: {ready: true}}\n' "$ip" "$node"
  done
  for vm in "${vms[@]}"; do
    read -r name node ip <<< "$vm"
    uid=$(kubectl get node "$node" -o jsonpath='{.metadata.uid}')
    node_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    cat <<YAML
---
# ownerReferences が Pod 以外なので cilium-operator の CEP GC 対象にならない。Node 削除時に連動して消える。
apiVersion: cilium.io/v2
kind: CiliumEndpoint
metadata:
  name: $name
  namespace: lab-vm
  ownerReferences:
    - {apiVersion: v1, kind: Node, name: $node, uid: $uid}
status:
  identity: {id: 2}
  networking:
    addressing:
      - {ipv4: $ip}
    node: $node_ip
YAML
  done
} | case "${1:-apply}" in
  apply) kubectl apply -f - ;;
  delete) kubectl delete --ignore-not-found -f - ;;
  render) cat ;;
esac
