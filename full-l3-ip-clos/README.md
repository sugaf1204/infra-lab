# Full L3 IP Clos

2 台の spine と 2 台の leaf を結ぶ IPv4 Clos。leaf–spine はすべてインターフェース指定の eBGP Unnumbered で接続する。IPv6 link-local は自動生成され、IPv4 プレフィックスを IPv6 next hop 付きで交換する。各 leaf が直結するホスト用 /24 を eBGP で広告し、対向 leaf は 2 台の spine を ECMP next hop として使う。

## 論理構成

```mermaid
flowchart TB
    S1["spine1 · FRR コンテナ · AS65001"]
    S2["spine2 · FRR コンテナ · AS65002"]
    L1["leaf1 · FRR コンテナ · AS65101"]
    L2["leaf2 · FRR コンテナ · AS65102"]
    H1["host1 · Linux コンテナ · 10.211.1.2"]
    H2["host2 · Linux コンテナ · 10.211.2.2"]
    S1 ---|"Unnumbered · eth1 ↔ eth1"| L1
    S2 ---|"Unnumbered · eth1 ↔ eth2"| L1
    S1 ---|"Unnumbered · eth2 ↔ eth1"| L2
    S2 ---|"Unnumbered · eth2 ↔ eth2"| L2
    L1 ---|"10.211.1.0/24"| H1
    L2 ---|"10.211.2.0/24"| H2
```

| 接続 | インターフェースまたはサブネット |
| --- | --- |
| leaf1 – spine1 | leaf1 eth1 ↔ spine1 eth1 |
| leaf1 – spine2 | leaf1 eth2 ↔ spine2 eth1 |
| leaf2 – spine1 | leaf2 eth1 ↔ spine1 eth2 |
| leaf2 – spine2 | leaf2 eth2 ↔ spine2 eth2 |
| host1 – leaf1 | 10.211.1.0/24 |
| host2 – leaf2 | 10.211.2.0/24 |

## 起動と検証

[共通セットアップ](../common/README.md)後、このディレクトリで実行する。

```bash
sudo containerlab deploy -t topology.clab.yml
sudo ./verify.sh
sudo ./verify.sh --failover
```

通常の検証では全 4 本の BGP セッション、対向 /24 ごとの 2 経路の FIB 登録、ホスト間の双方向 ping を確認する。障害試験では leaf1 の spine1 側リンクを落とし、両 leaf の next hop が spine2 だけに収束した後の双方向 ping を確認する。復旧後は 2 経路への復帰と疎通を再確認する。スクリプトは試験失敗時もリンクを復元する。

```bash
sudo docker exec clab-full-l3-ip-clos-leaf1 vtysh -c 'show bgp ipv4 unicast summary'
sudo docker exec clab-full-l3-ip-clos-leaf1 vtysh -c 'show ip route 10.211.2.0/24'
sudo containerlab destroy --cleanup -t topology.clab.yml
```
