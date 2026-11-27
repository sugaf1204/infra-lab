#!/usr/bin/env bash
# compute ノード（Kind ノードのネットワーク名前空間）のホスト側ネットワーク準備。
# 実機では Netplan / systemd-networkd に相当する。冪等。
#
#   leaf ── k8s-leaf1/2 ── [ホストカーネル: FRR + Cilium] ── ovn-host0 ══ ovn-up0 ── br-bgp-0 ── OVN
#
# OVN BGP の「ピア」は ToR ではなくホストカーネル。VM の往復はホストの経路表と Cilium を通る。
set -euo pipefail

node=$1      # Kind ノード（コンテナ）名
address=$2   # ノードのループバック IP
host_mac=02:00:00:00:00:fe                # ovn-host0 の固定 MAC（全 compute 共通、リンクローカル）
host_ll=fe80::ff:fe00:fe                  # 上記 MAC の EUI-64 リンクローカル
tenant_cidrs=${TENANT_CIDRS:-10.250.0.0/24}  # flat provider network のサブネット（vm.sh と揃える）
system_id=${3:-}                          # OVN の chassis 名（ovn-controller 起動後に決まる）

# chassis ルーターの peer bridge 向け LRP のリンクローカル。plugin は LRP 名の UUIDv5 から MAC を決める
# （neutron/services/bgp/helpers.py の get_mac_address_from_lrp_name と同じ計算）。
lrp_ll=
if [[ -n $system_id ]]; then
  lrp_ll=$(python3 - "$system_id" <<'PY'
import sys, uuid
sid = sys.argv[1]
name = f"bgp-lrp-bgp-lr-{sid}-to-bgp-ls-{sid}-br-bgp-0"
mac = bytearray(uuid.uuid5(uuid.UUID("9eaaac59-33fc-4f45-a450-8c220d46ad95"), name).bytes[-6:])
mac[0] = (mac[0] | 0x02) & 0xfe
eui = bytes([mac[0] ^ 0x02, mac[1], mac[2], 0xff, 0xfe, mac[3], mac[4], mac[5]])
print("fe80::" + ":".join(f"{(eui[i] << 8) | eui[i + 1]:x}" for i in range(0, 8, 2)))
PY
)
fi

docker exec -i "$node" bash -s <<SCRIPT
set -euo pipefail
ip link show ovn-host0 >/dev/null 2>&1 || ip link add ovn-host0 address $host_mac type veth peer name ovn-up0
ip link set ovn-host0 up
ip link set ovn-up0 up
ip link show ovn-encap0 >/dev/null 2>&1 || ip link add ovn-encap0 type dummy
ip link set ovn-encap0 up
ip addr replace $address/32 dev ovn-encap0
sysctl -qw net.ipv4.conf.ovn-host0.rp_filter=0 net.ipv4.conf.ovn-host0.forwarding=1 \
  net.ipv6.conf.ovn-host0.accept_ra=0 net.ipv6.conf.ovn-up0.accept_ra=0

# fabric から届いた（または Cilium が Geneve DSR を終端した）テナント宛てパケットをテーブル 100 経由で OVN に渡す。
#  - Cilium は local テーブルの参照を pref 100 に移すため、それより後ろ（111）に置く。
#  - 宛先をテナント CIDR に限定する。iif だけのルールにすると、Cilium が戻りパケットの書き戻し時に
#    Leaf 向け NIC を入力 IF として行う FIB 検索（bpf_fib_lookup）にも一致し、戻りが OVN へ折り返す。
#  - この compute が広告した /32 宛てしか fabric からは届かないので、CIDR 全体を OVN に向けてよい。
#    ホスト自身や Pod が出す通信は一致させない（他 compute の VM 宛ては fabric 経由で届ける）。
while ip rule del pref 111 2>/dev/null; do :; done
for cidr in $tenant_cidrs; do
  for dev in k8s-leaf1 k8s-leaf2 cilium_geneve; do
    ip rule add pref 111 iif \$dev to \$cidr lookup 100
  done
done

# chassis ルーター（VRF ID 10）が学習する外向きデフォルト。OVN は proto static 以下の経路を学習しないため、
# 動的経路扱いになる独自のプロトコル番号（250）で入れる。ネクストホップはホストの ovn-host0。
# br-bgp-0 は OVN 導入後に現れるため、その後の再実行で入る。
if ip link show br-bgp-0 >/dev/null 2>&1 && [ -n "$lrp_ll" ]; then
  # ホスト → OVN。ネクストホップは LRP のリンクローカル。ホストが LRP に近隣要請を送ることで、
  # OVN 側もホスト（ovn-host0）の MAC を学習する。
  ip -4 route replace 0.0.0.0/0 via inet6 $lrp_ll dev ovn-host0 table 100
  ip link set br-bgp-0 up
  sysctl -qw net.ipv6.conf.br-bgp-0.accept_ra=0
  ip -4 route replace 0.0.0.0/0 via inet6 $host_ll dev br-bgp-0 table 10 proto 250
fi
SCRIPT
