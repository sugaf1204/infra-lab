#!/usr/bin/env bash
# H1〜H5 の観測点を機械的に照合する。--failover で Leaf 片系断と復旧、--withdraw で VM 経路の撤回も確認する。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export KUBECONFIG=$PWD/osk-bgp.kubeconfig

lab=clab-osk-bgp
client=$lab-client
client_ip=10.212.255.100
leaves=($lab-leaf1 $lab-leaf2)
l4lb_nodes=(osk-bgp-worker osk-bgp-worker2)
vip_pod=10.240.250.10        # L4LB → L7LB ノード上の Pod（whoami）
vip_vm=10.240.250.20         # L4LB → VM 直接
vip_l7_worker=10.240.250.30  # L4LB → L7LB（専用ワーカー）→ VM
vip_l7_compute=10.240.250.31 # L4LB → L7LB（compute の DaemonSet）→ VM
vips=($vip_pod $vip_vm $vip_l7_worker $vip_l7_compute)
# VM 固定 IP と、広告元 compute が Leaf のどのポートにつながるか（nodes.yml の定義順: client=eth3 ... cmp1=eth9, cmp2=eth10）
declare -A vm_port=([10.250.0.11]=eth9 [10.250.0.12]=eth10)
l4lb_ports='["eth5","eth6"]'

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
http() { docker exec "$client" wget -q -S -T 4 -O - "http://$1/" 2>&1; }
node_ns() { nsenter -t "$(docker inspect -f '{{.State.Pid}}' "$1")" -n "${@:2}"; }

route_devs() { # leaf prefix → 次ホップのデバイス名（ソート済み JSON 配列）
  docker exec "$1" ip -j -4 route show exact "$2" |
    jq -c '[.[] | select(.protocol == "bgp") | (.nexthops // [.])[] | .dev] | sort'
}

check_routes() {
  local up_leaves=("$@") leaf vip ip
  for leaf in "${up_leaves[@]}"; do
    for vip in "${vips[@]}"; do
      [[ $(route_devs "$leaf" "$vip/32") == "$l4lb_ports" ]] || return 1
    done
    for ip in "${!vm_port[@]}"; do
      [[ $(route_devs "$leaf" "$ip/32") == "[\"${vm_port[$ip]}\"]" ]] || return 1
    done
  done
}

check_traffic() {
  local out ip
  # H2: Pod が見た送信元がクライアントのループバック
  http $vip_pod | grep -q "^RemoteAddr: $client_ip:" || return 1
  # H3: VM 固定 IP へ直接
  for ip in "${!vm_port[@]}"; do
    docker exec "$client" ping -c 1 -W 2 "$ip" >/dev/null || return 1
    http "$ip" | grep -q '^vm=vm' || return 1
  done
  # H4: VIP → VM（DSR）
  http $vip_vm | grep -q '^vm=vm' || return 1
  # L7LB 経由。L7LB が見た送信元がクライアントのループバック
  for ip in $vip_l7_worker $vip_l7_compute; do
    out=$(http "$ip") || return 1
    grep -q "X-L7LB-Client: $client_ip" <<< "$out" && grep -q '^vm=vm' <<< "$out" || return 1
  done
}

wait_for() { # 説明 コマンド...
  local what=$1 attempt
  shift
  for ((attempt = 0; attempt < 30; attempt++)); do
    if "$@"; then pass "$what"; return 0; fi
    sleep 2
  done
  fail "$what"
}

set_leaf_host_links() { # leaf up|down: ホスト向けポート（eth3 以降）を一括操作
  local port
  for port in $(docker exec "$1" sh -c 'ls /sys/class/net | grep -E "^eth([3-9]|[1-9][0-9])$"'); do
    docker exec "$1" ip link set "$port" "$2"
  done
}

check_dsr() {
  # H4 の観測: VM の tap では「クライアント IP → VM 固定 IP」、compute の Leaf 向け NIC からは「VIP → クライアント」、
  # L4LB ノードには戻りパケットが現れない。
  local tmp pids=() node tap n
  tmp=$(mktemp -d)
  for node in osk-bgp-worker5 osk-bgp-worker6; do
    for tap in $(node_ns "$node" ip -o link | awk -F': ' '{print $2}' | grep -E '^tap[0-9a-f]{8}-[0-9a-f]{2}$'); do
      timeout 8 nsenter -t "$(docker inspect -f '{{.State.Pid}}' "$node")" -n \
        tcpdump -nli "$tap" "tcp dst port 80 and src host $client_ip and tcp[tcpflags] & tcp-syn != 0" \
        > "$tmp/tap-$node" 2>/dev/null &
      pids+=($!)
    done
    timeout 8 nsenter -t "$(docker inspect -f '{{.State.Pid}}' "$node")" -n \
      tcpdump -nli any "tcp src port 80 and src host $vip_vm and dst host $client_ip" > "$tmp/egress-$node" 2>/dev/null &
    pids+=($!)
  done
  for node in "${l4lb_nodes[@]}"; do
    timeout 8 nsenter -t "$(docker inspect -f '{{.State.Pid}}' "$node")" -n \
      tcpdump -nli any "tcp src port 80 and dst host $client_ip" > "$tmp/return-$node" 2>/dev/null &
    pids+=($!)
  done
  sleep 1
  for n in $(seq 12); do http $vip_vm >/dev/null || true; done
  wait "${pids[@]}" || true
  for node in osk-bgp-worker5 osk-bgp-worker6; do
    grep -Eq "IP $client_ip\.[0-9]+ > 10\.250\.0\.[0-9]+\.80:" "$tmp/tap-$node" || fail "VM の tap（$node）でクライアント IP を観測できない"
    grep -q "IP $vip_vm.80 > $client_ip" "$tmp/egress-$node" || fail "$node から VIP 送信元の応答が出ていない"
  done
  for node in "${l4lb_nodes[@]}"; do
    ! grep -q " IP " "$tmp/return-$node" || { grep " IP " "$tmp/return-$node" | head -5 >&2; fail "L4LB ノード $node に戻りパケットが現れた"; }
  done
  rm -rf "$tmp"
  pass 'H4: VM はクライアント IP を受信、応答は compute から VIP 送信元で直接返り、L4LB を通らない'
}

kubectl wait --for=condition=Ready --timeout=180s node --all >/dev/null
! kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1 || fail 'kube-proxy が存在する'
pass 'kube-proxy なし、全ノード Ready'

# H1: 全ノードで Leaf 2 本 + Cilium のピアが Established。VIP は L4LB 2 台の ECMP だけ。
for node in cp l4lb1 l4lb2 l7lb1 osctl1 cmp1 cmp2; do
  docker exec "$lab-$node" vtysh -c 'show bgp ipv4 unicast summary json' 2>/dev/null | jq -e '
    .peers as $p | ($p["127.0.0.2"].state == "Established")
    and all(["k8s-leaf1","k8s-leaf2"][]; $p[.].state == "Established" and $p[.].idType == "interface")
  ' >/dev/null || fail "$node の BGP ピアが揃っていない"
done
pass 'H1: 全ノードが両 Leaf（Unnumbered）とホスト内 Cilium にピア確立'
wait_for 'H1/H3: VIP は L4LB 2 台の ECMP、VM /32 は収容 compute のポートだけ（両 Leaf）' check_routes "${leaves[@]}"
wait_for 'H2〜H4: Pod・VM 固定 IP・VIP→VM・L7LB（専用ワーカー / compute）の HTTP' check_traffic
check_dsr

if [[ ${1:-} == --failover ]]; then
  for i in 0 1; do
    down=${leaves[$i]} up=${leaves[$((1 - i))]}
    set_leaf_host_links "$down" down
    wait_for "H5: $down 片系断中の経路（$up）" check_routes "$up"
    wait_for "H5: $down 片系断中の通信" check_traffic
    set_leaf_host_links "$down" up
    wait_for "H5: $down 復旧後の経路" check_routes "${leaves[@]}"
    wait_for "H5: $down 復旧後の通信" check_traffic
  done
fi

if [[ ${1:-} == --withdraw ]]; then
  # H3: VM を削除すると /32 が撤回され、作り直すと再広告される。
  ./vm.sh delete vm2 >/dev/null
  withdrawn() { [[ $(route_devs "${leaves[0]}" 10.250.0.12/32) == '[]' && $(route_devs "${leaves[1]}" 10.250.0.12/32) == '[]' ]]; }
  wait_for 'H3: vm2 削除で 10.250.0.12/32 が両 Leaf から撤回' withdrawn
  ./vm.sh up >/dev/null
  wait_for 'H3: vm2 再作成で再広告' check_routes "${leaves[@]}"
  wait_for 'H3: 再作成後の通信' check_traffic
fi
echo 'ALL PASS'
