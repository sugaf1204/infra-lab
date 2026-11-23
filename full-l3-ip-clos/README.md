# Full L3 IP Clos（共有 2-Spine / 2-Leaf ファブリック + NAT）

全ラボ共通の 2-Spine / 2-Leaf IPv4 Clos ファブリックと外向き NAT ゲートウェイ。`infra-lab-switches` 上で 1 つの Containerlab トポロジー（`full-l3-ip-clos`）として稼働し、Kubernetes Kind ノード（`node0`/`node1`）と OpenStack chassis（`controller`/`compute`）を同じ 2 台の Leaf（`leaf1`/`leaf2`）に収容する。

## 設計と NAT IP 非流出の仕組み

- **NAT 本体（`nat`, AS `65099`）**: 外向き `eth0` で `MASQUERADE` を行い、内側 `eth1` / `eth2` で `spine1` / `spine2` と接続する（2-way ECMP）。Spine からラボ内の `/32` ホストルートのみを受信し、NAT からは一切の経路を広告しない（`DENY-ALL out`）。
- **共有 Spine（`spine1` / `spine2`, AS `65001` / `65002`）**: NAT 向けのデフォルトルート（`ip route 0.0.0.0/0 <NAT_IP>`）を **Spine の静的ルートとしてのみ** 設定し、`redistribute static route-map DEFAULT-ONLY` で `0.0.0.0/0` のみを Leaf へ広告する。NAT の IP や NAT リンクの `/30` は BGP に載せない。
- **共有 Leaf（`leaf1` / `leaf2`, AS `65101` / `65102`）**: 2 台の Spine から 2-way ECMP でデフォルト経路を学習し、全ホストに対して eBGP Unnumbered（`remote-as external`）で `0.0.0.0/0` のみを広告し、`/32` ホストルートのみを受信する。`leaf1`/`leaf2` および全ホストの BGP テーブル・FIB には NAT の IP は一切流出しない。
- **各ホスト**: IPv6 リンクローカル next hop の IPv4 デフォルト（2-way ECMP）のみを学習し、ラボ内通信・外向き通信のいずれもこのデフォルト経路で行う。全ノードで `net.ipv4.fib_multipath_hash_policy=1`（L4 ハッシュ）を有効化する。

| `leaf1`/`leaf2` ポート | 接続先 | 用途 |
| :--- | :--- | :--- |
| `eth1` / `eth2` | `spine1` / `spine2` | 2-Spine アップリンク（2-way ECMP） |
| `eth3` / `eth4` | `node0` / `node1` (`k8s-leaf1`/`k8s-leaf2`) | Kubernetes Kind ノード相乗り FRR（`10.220.255.10/32`, `10.220.255.11/32`） |
| `eth5` / `eth6` | `ovn-ctl-tor*` / `ovn-tor*` | OpenStack controller / compute chassis（`203.0.113.31/32`, `203.0.113.32/32`） |

## 起動・検証・撤去

`infra-lab-switches` で管理 NIC に `192.168.122.1` への外向きルートを有効化した状態で実行する。

```bash
sudo ./lab.sh up
sudo ./verify.sh
sudo ./verify.sh --failover
sudo ./lab.sh down
```

## 実機検証結果（2026-11-24）

`infra-lab-switches`（4 vCPU / 6 GiB、Containerlab 0.83.0 / FRR 10.4.1）で共有 2-Spine / 2-Leaf + NAT ファブリックを展開し、Kubernetes・OpenStack の両ラボを同時収容した状態で以下を確認した。

- **NAT IP 非流出**: `leaf1` / `leaf2`・K8s `node0` / `node1`・OpenStack 両 chassis の BGP テーブルおよび FIB に `100.64.0.`（NAT IP / サブネット）が一切存在しないことを確認。
- **外向き通信**: `leaf1` / `leaf2`、K8s `node0` / `node1`・両 Pod、OpenStack 両 chassis から BGP デフォルト（IPv6 LL 2-way ECMP）→ 共有 Leaf → 共有 Spine → `nat` 経由で `1.1.1.1` への ping が損失 0% で疎通することを確認。
- **障害復旧**: `verify.sh --failover`（正常時・`spine1` 片系断・復旧・`spine2` 片系断・復旧）が終了コード 0 で通過。
