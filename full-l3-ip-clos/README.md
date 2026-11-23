# Full L3 IP Clos

2 台の spine と 2 台の ToR を結ぶ IPv4 Clos。host1 と host2 は、それぞれ独立した `eth1` と `eth2` で leaf1 と leaf2 に接続する。各ホストは `lo` のノード IP を /32 で両 ToR に広告し、両 ToR から IPv4 デフォルト `0.0.0.0/0` のみを学習する。デフォルト経路の next hop は IPv6 リンクローカルで、`set src` により自ノードのループバック IP が送信元として選ばれる。全リンクが `remote-as external` を使ったインターフェース指定の eBGP Unnumbered であり、各ノードの FRR 設定には自ノードのループバック IP 以外の IP アドレスを記述しない。コンテナは管理ネットワークに接続せず、DHCP と静的経路を使わない。また全ノードで `net.ipv4.fib_multipath_hash_policy=1`（L4 ハッシュ）を有効化する。

## 検証ネットワーク

![2 台の spine と 2 台の ToR、および ToR へ二重接続したホスト](network.svg)

[図のソース](network.dot)

すべての実線は veth とその上の eBGP Unnumbered セッションを示す。各ホストの2本のリンクは独立した L3 インターフェースとして扱う。

spine は自身のループバック /32 を ToR に広告する。ToR がホストに広告するのはデフォルトのみなので、ホストから対向ホストおよび両 spine のループバックへの通信はすべてデフォルト経路の転送を検証できる。既存の spine を宛先に使い、追加ノードは不要。

## 起動と検証

[共通セットアップ](../common/README.md)後、このディレクトリで実行する。旧トポロジーを使っている場合は、旧チェックアウトでラボを停止してから切り替える。

```bash
sudo containerlab deploy -t topology.clab.yml
sudo ./verify.sh
sudo ./verify.sh --failover
```

通常の検証では全8本の BGP セッション、両ホストの IPv4 デフォルト ECMP、両 ToR の直接学習経路、両 spine のホスト /32 への ECMP を確認する。また各ホストで対向ホストおよび両 spine 宛てのカーネル経路検索が BGP のデフォルトに一致することを確認してから、送信元指定なしの ping を送る。障害試験では ToR ごとにホスト側の2本を止め、経路が残る ToR へ収束した状態で ping を繰り返し、復旧後に ECMP と疎通を再確認する。

```bash
sudo docker exec clab-full-l3-ip-clos-host1 ip -4 route show default
sudo docker exec clab-full-l3-ip-clos-host1 ip -4 route get fibmatch 10.211.255.3
sudo docker exec clab-full-l3-ip-clos-spine1 vtysh -c 'show ip route 10.211.2.2/32'
sudo containerlab destroy --cleanup -t topology.clab.yml
```

## 未検証の項目

- `remote-as external`・`frr defaults datacenter` 統一・ホストのデフォルトのみ学習（`set src` 付与）・`fib_multipath_hash_policy=1` への変更後の実機での `verify.sh --failover` 再検証。
