#!/usr/bin/env bash
set -euo pipefail

failover=${1:-}
control_node=cilium-l3-control-plane
worker_node=cilium-l3-worker
control_ip=10.220.255.10
worker_ip=10.220.255.11
vip=10.220.250.10
client_ip=10.220.240.14
tors=(clab-cilium-l3-tor1 clab-cilium-l3-tor2)
client=clab-cilium-l3-client
nodes=(clab-cilium-l3-node0 clab-cilium-l3-node1)

check_peers() {
  docker exec "$1" vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e --argjson interfaces "$2" '
      .peers | keys == $interfaces and all(.[]; .state == "Established" and .idType == "interface")
    ' >/dev/null
}

check_routes() {
  local interfaces=$1
  shift
  "$@" | jq -e --argjson interfaces "$interfaces" '
    [.[] | select(.protocol == "bgp") | (.nexthops // [.])[] |
      select((.via.host // .gateway // "") | startswith("fe80:")) | .dev] | sort == ($interfaces | sort)
  ' >/dev/null
}

check_node() {
  local ctr=$1 node_ip=$2 other_ip=$3
  docker exec "$ctr" ip -j -4 address show dev lo | jq -e --arg ip "$node_ip" \
    '[.[].addr_info[] | select(.scope == "global")] | length == 1 and .[0].local == $ip and .[0].prefixlen == 32' >/dev/null
  docker exec "$ctr" vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e '
      .peers as $p | ($p["127.0.0.2"].state == "Established" and $p["127.0.0.2"].remoteAs == 65201)
      and all(["k8s-tor1","k8s-tor2"][]; $p[.].state == "Established" and $p[.].idType == "interface")
    ' >/dev/null
  check_routes '["k8s-tor1","k8s-tor2"]' docker exec "$ctr" ip -j -4 route show default
  docker exec "$ctr" ip -j -4 route show default | jq -e 'length == 1 and .[0].protocol == "bgp"' >/dev/null
  docker exec "$ctr" ip -j -4 route get fibmatch "$other_ip" | jq -e '.[0].dst == "default"' >/dev/null
  docker exec "$ctr" ip -j -4 route get fibmatch "$client_ip" | jq -e '.[0].dst == "default"' >/dev/null
  docker exec "$ctr" ping -c 2 -W 2 "$other_ip"
  docker exec "$ctr" ping -c 2 -W 2 "$client_ip"
}

fabric_traffic() {
  local interfaces=$1 tor address
  shift
  for tor in "$@"; do
    check_routes '["eth1","eth3"]' docker exec "$tor" ip -j -4 route show exact "$vip/32" || return 1
  done
  for address in "$control_ip" "$worker_ip" "$vip"; do
    check_routes "$interfaces" docker exec "$client" ip -j -4 route show exact "$address/32" || return 1
  done
  docker exec "$client" ping -c 2 -W 2 "$control_ip" &&
    docker exec "$client" ping -c 2 -W 2 "$worker_ip" &&
    docker exec "$client" wget -q -T 5 -O - "http://$vip/" | grep -Fx probe
}

wait_for_fabric_traffic() {
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if fabric_traffic "$@"; then return 0; fi
    sleep 2
  done
  return 1
}

set_tor_links() {
  local interface
  for interface in eth1 eth2 eth3; do
    docker exec "$1" ip link set "$interface" "$2"
  done
}

probe_info() {
  kubectl -n lab-probe get pods -l app=probe --field-selector "spec.nodeName=$1" -o json |
    jq -er '.items | select(length == 1) | .[0] | [.metadata.name, .status.podIP] | @tsv'
}

kubectl wait --for=condition=Ready --timeout=180s "node/$control_node" "node/$worker_node"
if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
  echo 'kube-proxy DaemonSet must not be present.' >&2
  exit 1
fi
kubectl -n lab-probe rollout status daemonset/probe --timeout=180s
kubectl -n lab-probe wait --timeout=120s --for="jsonpath={.status.loadBalancer.ingress[0].ip}=$vip" service/probe
kubectl get node "$control_node" "$worker_node" -o json |
  jq -e --arg control "$control_ip" --arg worker "$worker_ip" '
    [.items[].status.addresses[] | select(.type == "InternalIP").address] | sort == [$control,$worker]
  ' >/dev/null

check_node "${nodes[0]}" "$control_ip" "$worker_ip"
check_node "${nodes[1]}" "$worker_ip" "$control_ip"

IFS=$'\t' read -r control_pod control_pod_ip <<< "$(probe_info "$control_node")"
IFS=$'\t' read -r worker_pod worker_pod_ip <<< "$(probe_info "$worker_node")"
for pod in "$control_pod" "$worker_pod"; do
  kubectl -n lab-probe exec "$pod" -- ping -c 2 -W 2 "$client_ip"
done
kubectl -n lab-probe exec "$control_pod" -- ping -c 2 -W 2 "$worker_pod_ip"
kubectl -n lab-probe exec "$worker_pod" -- ping -c 2 -W 2 "$control_pod_ip"

check_peers "$client" '["eth1","eth2"]'
for tor in "${tors[@]}"; do
  check_peers "$tor" '["eth1","eth2","eth3"]'
done
wait_for_fabric_traffic '["eth1","eth2"]' "${tors[@]}"

if [[ $failover == --failover ]]; then
  trap 'for tor in "${tors[@]}"; do set_tor_links "$tor" up || true; done' EXIT
  for index in "${!tors[@]}"; do
    surviving_tor=${tors[1 - index]}
    printf 'Testing failover with %s down\n' "${tors[index]}"
    set_tor_links "${tors[index]}" down
    wait_for_fabric_traffic "[\"eth$((2 - index))\"]" "$surviving_tor"
    set_tor_links "${tors[index]}" up
    wait_for_fabric_traffic '["eth1","eth2"]' "${tors[@]}"
  done
  trap - EXIT
fi
