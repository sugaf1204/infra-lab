#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf
control_node=cilium-l3-node
control_ip=10.220.255.10
worker_node=cilium-l3-worker
worker_ip=10.220.255.11
vip=10.220.250.10
client_ip=10.220.240.14
tors=(clab-cilium-l3-tor1 clab-cilium-l3-tor2)
client=clab-cilium-l3-client
failover=${2:-}
case "$(hostname -s)" in
  infra-lab-k8s-control) role=control-plane; node_ip=$control_ip ;;
  infra-lab-k8s-worker) role=worker; node_ip=$worker_ip ;;
  *) role=fabric ;;
esac

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

check_default() {
  local links=$1
  shift
  check_routes "$links" "$@" -j -4 route show default &&
    "$@" -j -4 route show default | jq -e 'length == 1 and .[0].protocol == "bgp"' >/dev/null &&
    "$@" -j -4 route get fibmatch "$client_ip" | jq -e '.[0].dst == "default"' >/dev/null
}

set_tor_links() {
  local interface
  for interface in eth1 eth2 eth3; do
    docker exec "$1" ip link set "$interface" "$2"
  done
}

verify_node() {
  local other_ip=$worker_ip
  if [[ $role == worker ]]; then other_ip=$control_ip; fi
  ip -j -4 address show dev lo | jq -e --arg ip "$node_ip" \
    '[.[].addr_info[] | select(.scope == "global")] | length == 1 and .[0].local == $ip and .[0].prefixlen == 32' >/dev/null
  ip -d -j link show | jq -e 'all(.[]; .linkinfo.info_kind != "vrf" and .linkinfo.info_kind != "bridge")' >/dev/null
  vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e '
      .peers as $p | ($p["127.0.0.2"].state == "Established" and $p["127.0.0.2"].remoteAs == 65201)
      and all(["k8s-tor1","k8s-tor2"][]; $p[.].state == "Established" and $p[.].idType == "interface")
    ' >/dev/null
  check_default '["k8s-tor1","k8s-tor2"]' ip
  ip -j -4 route get fibmatch "$other_ip" | jq -e '.[0].dst == "default"' >/dev/null
  ping -c 2 -W 2 "$other_ip"
  ping -c 2 -W 2 "$client_ip"
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

verify_fabric() {
  local index surviving_tor
  check_peers "$client" '["eth1","eth2"]'
  for index in "${!tors[@]}"; do
    check_peers "${tors[index]}" '["eth1","eth2","eth3"]'
  done
  wait_for_fabric_traffic '["eth1","eth2"]' "${tors[@]}"
  if [[ $failover == --failover ]]; then
    trap 'for tor in "${tors[@]}"; do set_tor_links "$tor" up || true; done' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for index in "${!tors[@]}"; do
      surviving_tor=${tors[1 - index]}
      printf 'Testing failover with %s down\n' "${tors[index]}"
      set_tor_links "${tors[index]}" down
      wait_for_fabric_traffic "[\"eth$((2 - index))\"]" "$surviving_tor"
      set_tor_links "${tors[index]}" up
      wait_for_fabric_traffic '["eth1","eth2"]' "${tors[@]}"
    done
    trap - EXIT INT TERM
  fi
}

probe_info() {
  kubectl -n lab-probe get pods -l app=probe --field-selector "spec.nodeName=$1" -o json |
    jq -er '.items | select(length == 1) | .[0] | [.metadata.name, .status.podIP] | @tsv'
}

verify() {
  local control_pod control_pod_ip worker_pod worker_pod_ip worker_cilium result pod
  kubectl wait --for=condition=Ready --timeout=180s "node/$control_node" "node/$worker_node"
  if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
    echo 'kube-proxy DaemonSet must not be present.' >&2
    return 1
  fi
  kubectl -n lab-probe rollout status daemonset/probe --timeout=180s
  kubectl -n lab-probe wait --timeout=120s \
    --for="jsonpath={.status.loadBalancer.ingress[0].ip}=$vip" service/probe
  kubectl get node "$control_node" "$worker_node" -o json |
    jq -e --arg control "$control_ip" --arg worker "$worker_ip" '
      [.items[].status.addresses[] | select(.type == "InternalIP").address] | sort == [$control,$worker]
    ' >/dev/null
  result=$(probe_info "$control_node")
  IFS=$'\t' read -r control_pod control_pod_ip <<< "$result"
  result=$(probe_info "$worker_node")
  IFS=$'\t' read -r worker_pod worker_pod_ip <<< "$result"
  worker_cilium=$(kubectl -n kube-system get pods -l k8s-app=cilium \
    --field-selector "spec.nodeName=$worker_node,status.phase=Running" \
    -o json | jq -er '.items | select(length == 1) | .[0].metadata.name')

  verify_node
  check_default '["k8s-tor1","k8s-tor2"]' kubectl -n kube-system exec "$worker_cilium" -- ip
  for pod in "$control_pod" "$worker_pod"; do
    kubectl -n lab-probe exec "$pod" -- ping -c 2 -W 2 "$client_ip"
  done
  kubectl -n lab-probe exec "$control_pod" -- ping -c 2 -W 2 "$worker_pod_ip"
  kubectl -n lab-probe exec "$worker_pod" -- ping -c 2 -W 2 "$control_pod_ip"
}

case "${1:-}" in
  cluster) verify ;;
  node) verify_node ;;
  fabric) verify_fabric ;;
  *) echo "Usage: $0 {cluster|node|fabric [--failover]}" >&2; exit 2 ;;
esac
