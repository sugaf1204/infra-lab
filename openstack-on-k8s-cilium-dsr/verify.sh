#!/usr/bin/env bash
# 正常時と、--failover 指定時は Leaf 片系断・復旧後の経路と疎通を確認する。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG=$PWD/osk8s.kubeconfig

client=clab-osk8s-client
client_ip=10.212.255.100
leaves=(clab-osk8s-leaf1 clab-osk8s-leaf2)
l7_vip=10.230.250.1   # L4LB -> L7LB 相当 Pod（専用 worker）
vm_vip=10.230.250.2   # L4LB -> OpenStack VM
vm_ips=(10.240.0.21 10.240.0.22)
host_ports=(eth4 eth5 eth6 eth7 eth8 eth9 eth10)

route_ports() { # <leaf> <prefix>: その経路の出力ポートを昇順で返す
  docker exec "$1" ip -j -4 route show exact "$2" |
    jq -c '[.[] | select(.protocol == "bgp") | (.nexthops // [.])[] | .dev] | sort'
}

fetch() { docker exec "$client" wget -q -T 3 -O - "http://$1/" 2>/dev/null; }

check() { # <稼働中の leaf...>
  local leaf out seen ip
  for leaf in "$@"; do
    # VIP は L4LB frontend（eth5/eth6）だけが広告する
    [[ $(route_ports "$leaf" "$l7_vip/32") == '["eth5","eth6"]' ]] || { echo "$leaf: $l7_vip not via L4LB only"; return 1; }
    [[ $(route_ports "$leaf" "$vm_vip/32") == '["eth5","eth6"]' ]] || { echo "$leaf: $vm_vip not via L4LB only"; return 1; }
    # VM 固定 IP /32 は VM が載る compute（eth9/eth10）が広告する
    [[ $(route_ports "$leaf" "${vm_ips[0]}/32") == '["eth9"]' ]] || { echo "$leaf: ${vm_ips[0]} not via cmp1"; return 1; }
    [[ $(route_ports "$leaf" "${vm_ips[1]}/32") == '["eth10"]' ]] || { echo "$leaf: ${vm_ips[1]} not via cmp2"; return 1; }
  done
  for ip in "${vm_ips[@]}"; do
    docker exec "$client" ping -q -c 2 -W 2 "$ip" >/dev/null || { echo "ping $ip failed"; return 1; }
  done
  # L4LB -> L7LB: クライアント IP が保持されること
  out=$(fetch "$l7_vip") || { echo "GET $l7_vip failed"; return 1; }
  grep -q "^RemoteAddr: $client_ip:" <<<"$out" || { echo "L7LB saw: $out"; return 1; }
  # L4LB -> VM: クライアント IP が保持され、VIP で応答し、両 VM に分散されること
  seen=
  for _ in $(seq 1 16); do
    out=$(fetch "$vm_vip") || { echo "GET $vm_vip failed"; return 1; }
    grep -q "^RemoteAddr: $client_ip:" <<<"$out" || { echo "VM saw: $out"; return 1; }
    grep -q "^LocalAddr: $vm_vip$" <<<"$out" || { echo "VM replied from: $out"; return 1; }
    seen+="$(sed -n 's/^Hostname: //p' <<<"$out") "
  done
  [[ $(tr ' ' '\n' <<<"$seen" | sort -u | grep -c .) -eq 2 ]] || { echo "backends seen: $seen"; return 1; }
}

wait_check() {
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if msg=$(check "$@" 2>&1); then return 0; fi
    sleep 2
  done
  echo "$msg" >&2
  return 1
}

set_host_links() { # <leaf> <up|down>
  local port
  for port in "${host_ports[@]}"; do docker exec "$1" ip link set "$port" "$2"; done
}

if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
  echo 'kube-proxy DaemonSet must not be present.' >&2
  exit 1
fi
kubectl wait --for=condition=Ready --timeout=180s node --all >/dev/null
# compute の DaemonSet は hostNetwork で動く
kubectl -n openstack get pods -o json | jq -e '
  [.items[] | select(.metadata.ownerReferences[0].kind == "DaemonSet") | .spec.hostNetwork] | length > 0 and all' >/dev/null
wait_check "${leaves[@]}"
echo 'normal: ok'

if [[ ${1:-} == --failover ]]; then
  trap 'for leaf in "${leaves[@]}"; do set_host_links "$leaf" up || true; done' EXIT
  for index in 0 1; do
    set_host_links "${leaves[index]}" down
    wait_check "${leaves[1 - index]}"
    echo "${leaves[index]} down: ok"
    set_host_links "${leaves[index]}" up
    wait_check "${leaves[@]}"
    echo "${leaves[index]} restored: ok"
  done
  trap - EXIT
fi
