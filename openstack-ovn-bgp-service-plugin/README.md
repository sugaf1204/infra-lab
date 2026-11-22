# OpenStack OVN BGP Service Plugin

Neutron 2026.2 の組み込み `ovn-bgp` service plugin と OVN Neutron Agent を使う。CirrOS VM は flat provider network に直接接続し、固定 IP `10.53.0.22/32` を両 ToR に広告する。Neutron ルーターと Floating IP の作成は不要。図の `bgp-lr-main` はプラグインが OVN 内に作成する論理ルーター。 [Neutron 2026.2 の provider network 実装](https://github.com/openstack/neutron/blob/b82b437de7/neutron/services/bgp/commands.py#L271-L305)

## 検証ネットワーク

![Dual ToR で二重接続した OpenStack chassis と、flat provider network 上の CirrOS VM](network.svg)

[図のソース](network.dot)

OpenStack chassis VM は Containerlab の `kind: host`。ToR 側の `eth1` をそれぞれ chassis の `ovnbgp-uplink` と `ovnbgp-uplink1` に接続し、独立した OVS ブリッジ `br-bgp-0` と `br-bgp-1` に収容する。chassis FRR はその2つのブリッジをピアのインターフェースに指定し、`lo` のノード IP `203.0.113.31/32` と、OVN がテーブル 42 に追加した VM /32 を両 ToR に広告する。全4本のファブリックリンクで eBGP Unnumbered を使う。

chassis のテーブル 10 は IPv6 next hop 付きの IPv4 デフォルトを両 ToR から学習する。CirrOS のゲスト NIC は Neutron DHCP で構成される。provider network のゲートウェイは OVN BGP プラグインがサブネットの DHCP 設定から取り込む。

## 構築

[共通セットアップ](../common/README.md)で用意した Ubuntu 26.04 amd64 専用 VM で実行する。DevStack はパッケージとサービスを構成する。CirrOS は QEMU で起動する。

```bash
./setup-devstack.sh
sudo ./containerlab.sh deploy
```

`containerlab.sh` はホスト名が `infra-lab-openstack` の VM で動く。`deploy` は veth、ループバック、OVS 接続、FRR、chassis の経路ポリシーを構成する。デプロイ後にホスト側の設定だけを再適用する場合は `sudo ./containerlab.sh configure` を使う。旧トポロジーから移行する場合は旧チェックアウトで Containerlab を停止し、旧ラボのルーターとテナントネットワークを片付けてから切り替える。

## VM 固定 IP の検証

空のラボで CirrOS イメージを Glance に登録してから実行する。

```bash
source "$HOME/devstack-ovn-bgp/openrc" admin admin
openstack extension list --network | grep ovn-bgp
openstack network create --provider-physical-network public \
  --provider-network-type flat ovn-bgp-direct
openstack subnet create --network ovn-bgp-direct \
  --subnet-range 10.53.0.0/24 --gateway 10.53.0.1 ovn-bgp-direct-v4
openstack security group create ovn-bgp-icmp
openstack security group rule create --ingress --protocol icmp \
  --remote-ip 203.0.113.10/32 ovn-bgp-icmp
openstack flavor create --vcpus 1 --ram 512 --disk 1 ovn-bgp-tiny
openstack port create --network ovn-bgp-direct \
  --fixed-ip subnet=ovn-bgp-direct-v4,ip-address=10.53.0.22 \
  --security-group ovn-bgp-icmp ovn-bgp-vm-port
openstack server create --wait --image cirros-0.6.3-x86_64-disk \
  --flavor ovn-bgp-tiny --port ovn-bgp-vm-port ovn-bgp-vm
```

```bash
openstack router list
openstack floating ip list
sudo ovn-sbctl list Advertised_Route
sudo ip -4 route show table 42
sudo ip -4 route show table 10
sudo ./verify.sh advertised
sudo ./verify.sh reachable
sudo ./verify.sh failover
```

`advertised` は VM 固定 IP の /32 をテーブル 42、両 ToR と spine の FIB で確認する。併せて chassis のデフォルトと spine のノード /32 が ECMP になっていることを検証する。`reachable` は spine から chassis のループバックと VM の固定 IP に直接 ping する。`failover` は ToR の chassis 側リンクを順番に停止し、両宛先の経路と疎通がもう片方に収束し、復旧後に ECMP へ戻ることを確認する。実機では VM 再作成時に `ACTIVE` 直後に経路が再広告され、ゲストの DHCP 設定完了後に ping が通った。

## 撤去

```bash
openstack server delete --wait ovn-bgp-vm
sudo ./verify.sh withdrawn
openstack network delete ovn-bgp-direct
openstack security group delete ovn-bgp-icmp
openstack flavor delete ovn-bgp-tiny
sudo ./containerlab.sh destroy
```

VM を作成する前に失敗した場合や分離済みのポートが残っている場合は、ネットワークを削除する前に `openstack port delete ovn-bgp-vm-port` を実行する。DevStack 自体の切り戻しは共通手順に従う。
