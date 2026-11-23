# Full L3 IP Clos

2 台の spine と 2 台の ToR を結ぶ IPv4 Clos。host1 と host2 は、それぞれ独立した `eth1` と `eth2` で leaf1 と leaf2 に接続する。各ホストは `lo` のノード IP を /32 で両 ToR に広告し、両 ToR から IPv6 link-local next hop 付きの IPv6 デフォルトと、対向ホストの IPv4 /32 を学習する。全リンクがインターフェース指定の eBGP Unnumbered を使う。

## 検証ネットワーク

![2 台の spine と 2 台の ToR、および ToR へ二重接続したホスト](network.svg)

[図のソース](network.dot)

すべての実線は veth とその上の eBGP Unnumbered セッションを示す。各ホストの2本のリンクは独立した L3 インターフェースとして扱う。

## 起動と検証

[共通セットアップ](../common/README.md)後、このディレクトリで実行する。旧トポロジーを使っている場合は、旧チェックアウトでラボを停止してから切り替える。

```bash
sudo containerlab deploy -t topology.clab.yml
sudo ./verify.sh
sudo ./verify.sh --failover
```

通常の検証では全8本の BGP セッション、両ホストの IPv6 デフォルトと IPv4 /32 の ECMP、両 ToR の直接学習経路、両 spine のノード /32 への ECMP、ホスト間の双方向 ping を確認する。障害試験では ToR ごとにホスト側の2本を止め、両ホストの IPv6 デフォルトと IPv4 /32、および spine のノード /32 が残る ToR に収束することを確認する。両方の片系断で双方向 ping を行い、各試験後に ECMP へ戻ることを確認する。

```bash
sudo docker exec clab-full-l3-ip-clos-host1 ip -6 route show default
sudo docker exec clab-full-l3-ip-clos-spine1 vtysh -c 'show ip route 10.211.2.2/32'
sudo containerlab destroy --cleanup -t topology.clab.yml
```
