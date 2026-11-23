# OpenStack OVN BGP Service Plugin

Neutron 2026.2 の組み込み `ovn-bgp` service plugin と、2台の chassis の OVN Neutron Agent を使う。controller は Nova compute を兼ね、追加 compute はインスタンスを実行する。各 chassis の テナント VM は DevStack の `demo` プロジェクトが所有する非共有・内部の flat provider network に直接接続する。Neutron ルーターと Floating IP の作成は不要。`bgp-lr-main` はプラグインが OVN 内に作成する論理ルーター。 [Neutron 2026.2 の provider network 実装](https://github.com/openstack/neutron/blob/b82b437de7/neutron/services/bgp/commands.py#L271-L305)

## 検証ネットワーク

![OpenStack の両 chassis が Fabric VM 上の両 ToR に直結する構成](network-direct-tor.svg)

[図のソース](network-direct-tor.dot)

ToR と spine は fabric VM に置く。controller と追加 compute はそれぞれ両 ToR に独立した L2 セグメントで接続する。両 chassis で NIC 名は `ovn-tor1` と `ovn-tor2`、対応する OVS ブリッジ名は `br-bgp-0` と `br-bgp-1` に揃える。

| L2 セグメント | fabric VM の専用 NIC | ToR ポート | chassis の NIC |
| --- | --- | --- | --- |
| `infra-lab-ovn-ctl-tor1` | `ovn-ctl-tor1` | `leaf1:eth1` | controller `ovn-tor1` |
| `infra-lab-ovn-ctl-tor2` | `ovn-ctl-tor2` | `leaf2:eth1` | controller `ovn-tor2` |
| `infra-lab-ovn-tor1` | `ovn-tor1` | `leaf1:eth3` | compute `ovn-tor1` |
| `infra-lab-ovn-tor2` | `ovn-tor2` | `leaf2:eth3` | compute `ovn-tor2` |

コントローラー VM 内で compute のフレームを中継する案では、コントローラーの停止が compute の両 ToR リンクに波及する。fabric を物理ホスト上で動かす案は、物理ホストで FRR コンテナを実行する必要がある。採用構成は fabric VM 内にコンテナを隔離しながら、両 chassis の各リンクを独立させる。`containerlab.sh` は、fabric VM の専用 virtio NIC を対応する ToR のネットワーク名前空間に移す。表の ToR ポートはその virtio NIC 自体に対応する。

chassis FRR は OVS ブリッジのインターフェース名で両 ToR とピアを張る。ループバックは controller が `203.0.113.31/32`、compute が `203.0.113.32/32`。OVN がテーブル 42 に追加したローカル VM /32 を chassis が両 ToR に広告する。全6本の BGP ピアは eBGP Unnumbered。両 chassis は、IPv6 リンクローカル next hop の IPv4 デフォルト `0.0.0.0/0` を両 ToR から学習し、OVN が使用する `ovnvrf10` のテーブル 10 に入れる。spine の IPv4 プローブ /32 は ToR が学習し、chassis はデフォルトを使って到達する。`ovnvrf42` と `ovnvrf10` はプラグインが OVN と FRR の経路交換に使う。

両 chassis が使う [FRR テンプレート](frr/chassis.conf.in) は、ホスト名・ASN・ループバック IP を `configure` で受け取る。FRR は OVN の VRF 42 から再配布した IPv4 /32 と自ノードのループバックに BGP community `65233:42` を付与する。両 ToR はその community を持つ /32 を chassis 側ピアから受け付け、spine に広告する。テナント CIDR は Neutron のサブネットで定義するため、サブネット変更に合わせた FRR フィルターの更新は不要。

## ラボへの接続

管理端末から [共通手順](../common/README.md)で2台の管理 IP を確認する。管理 SSH は固定アドレスを使う。

```bash
ssh -J node3 ubuntu@CONTROLLER_IP
ssh -J node3 ubuntu@COMPUTE_IP
```

OpenStack CLI は controller VM 内で実行する。プロジェクトの VM を表示するには `demo`、compute サービスを確認するには `admin` を使う。

```bash
source "$HOME/devstack-ovn-bgp/openrc" demo demo
openstack server list
source "$HOME/devstack-ovn-bgp/openrc" admin admin
openstack compute service list --service nova-compute
```

## 構築

[共通セットアップ](../common/README.md)で Ubuntu 26.04 amd64 VM の `infra-lab-openstack` と `infra-lab-openstack-compute`、および fabric VM への4本のデータリンクを用意する。Docker と Containerlab の共通セットアップは fabric VM で実行する。テナント VM は cloud-init 対応イメージを使い、両 chassis の QEMU で起動する。VM 作成・起動はホストのメモリ条件を満たす必要がある。

controller で DevStack を起動する。既存 controller に compute だけを追加する場合は次の手順へ進む。

```bash
./setup-devstack.sh controller
```

compute の初回セットアップは DevStack の共有認証情報を標準入力で受け取る。認証情報の供給経路は環境のシークレット管理に従う。ログは compute の管理ユーザーだけが読めるようにする。

```bash
umask 077
./setup-devstack.sh compute CONTROLLER_IP < /path/to/provisioned/credential \
  > "$HOME/openstack-compute-setup.log" 2>&1
```

compute の DevStack が起動したら、controller で Nova のホストを検出し、両方のサービスが `up` であることを確認する。 [DevStack のマルチノード手順](https://docs.openstack.org/devstack/2026.2/guides/multinode-lab.html#configure-compute-nodes)

```bash
PATH="/opt/stack/data/venv/bin:$PATH" "$HOME/devstack-ovn-bgp/tools/discover_hosts.sh"
source "$HOME/devstack-ovn-bgp/openrc" admin admin
openstack compute service list --service nova-compute
```

controller 内で ToR を動かす旧構成から移行する場合は、旧チェックアウトの controller で `sudo ./containerlab.sh destroy` を実行する。その後、node3 で controller の旧 compute 中継用 NIC を取り外し、共通手順の新しい専用 NIC を取り付ける。

```bash
# fabric VM
sudo ./containerlab.sh deploy
# controller と compute のそれぞれ
sudo ./containerlab.sh configure
```

fabric VM の `deploy` は ToR と spine を起動し、専用 virtio NIC を ToR に割り当てる。各 chassis の `configure` はループバック、OVS、FRR、経路ポリシーを設定する。

直結構成から更新する場合は、fabric VM で稼働中のトポロジーを `sudo ./containerlab.sh destroy` で停止してから再度 `deploy` する。両 chassis で `configure` を再実行する。controller の旧 NIC 名はこの実行時に移行する。

## VM 固定 IP の検証

controller で管理者が `demo` 所有のネットワークと、検証 VM の配置先を指定する Nova availability zone を作る。cloud-init 対応イメージ `ubuntu-cloud` を Glance に用意する。テナント権限で DHCP 無効のサブネット、ポート、VM を作る。コンフィグドライブから固定 IP を設定する。管理者が provider 属性を指定することで、ML2 の flat ドライバーを使う。既存環境を移行する場合は、同名のネットワーク・flavor・セキュリティグループと controller 側の既存 VM を再利用し、追加 compute 側の VM を作る。 [ML2 flat ドライバーの実装](https://github.com/openstack/neutron/blob/b82b437de7/neutron/plugins/ml2/drivers/type_flat.py#L112-L114)

```bash
source "$HOME/devstack-ovn-bgp/openrc" admin admin
openstack flavor create --vcpus 1 --ram 1024 --disk 10 ovn-bgp-ubuntu
openstack aggregate create --zone ovn-bgp-controller ovn-bgp-controller
openstack aggregate add host ovn-bgp-controller infra-lab-openstack
openstack aggregate create --zone ovn-bgp-compute ovn-bgp-compute
openstack aggregate add host ovn-bgp-compute infra-lab-openstack-compute
openstack network create --project demo --internal --no-share \
  --provider-physical-network public --provider-network-type flat ovn-bgp-direct

source "$HOME/devstack-ovn-bgp/openrc" demo demo
openstack subnet create --network ovn-bgp-direct \
  --subnet-range 10.53.0.0/24 --no-dhcp --gateway none ovn-bgp-direct-v4
openstack security group create ovn-bgp-icmp
openstack security group rule create --ingress --protocol icmp \
  --remote-ip 203.0.113.10/32 ovn-bgp-icmp

openstack port create --network ovn-bgp-direct \
  --fixed-ip subnet=ovn-bgp-direct-v4,ip-address=10.53.0.22 \
  --security-group ovn-bgp-icmp ovn-bgp-vm-port
openstack server create --wait --image ubuntu-cloud --config-drive true \
  --flavor ovn-bgp-ubuntu --port ovn-bgp-vm-port \
  --availability-zone ovn-bgp-controller ovn-bgp-vm
openstack port create --network ovn-bgp-direct \
  --fixed-ip subnet=ovn-bgp-direct-v4,ip-address=10.53.0.23 \
  --security-group ovn-bgp-icmp ovn-bgp-compute-vm-port
openstack server create --wait --image ubuntu-cloud --config-drive true \
  --flavor ovn-bgp-ubuntu --port ovn-bgp-compute-vm-port \
  --availability-zone ovn-bgp-compute ovn-bgp-compute-vm
```

```bash
# controller
source "$HOME/devstack-ovn-bgp/openrc" admin admin
openstack network show ovn-bgp-direct -c project_id -c provider:network_type -c router:external -c shared
openstack server list --all-projects --long
openstack router list
openstack floating ip list
# fabric VM
sudo ./verify.sh advertised
sudo ./verify.sh reachable
sudo ./verify.sh failover
# controller と compute のそれぞれ
sudo ./verify.sh chassis
```

`advertised` は、テナント VM の `10.53.0.22/32` と `10.53.0.23/32` がそれぞれの chassis につながるインターフェース経由で両 ToR に入ることと、spine の ECMP を確認する。追加 compute では `chassis` がローカルの OVN 経路と両 ToR から学習したデフォルトを照合する。`failover` は ToR 側の chassis との接続を片系ずつ停止し、経路の収束と両 VM の固定 IP への ping を確認する。`advertised`、`reachable`、`failover`、`failover-routes` は `controller` または `compute` を引数に指定して片方だけを検証できる。`failover-routes` は収束と経路を確認する。

## DHCP 無効での制約

Neutron の固定版は、flat network の `bgp-lr-main` のインターフェース用アドレスを OVN の `DHCP_Options` から取得する。サブネットの DHCP を無効にすると ML2/OVN はこの行を作らない。VM の /32 が広告された場合も、DHCP 無効での OVN 内部の転送は別に検証する必要がある。 [BGP プラグイン](https://github.com/openstack/neutron/blob/b82b437de7/neutron/services/bgp/commands.py#L85-L100) · [OVN DHCP の実装](https://github.com/openstack/neutron/blob/b82b437de7/neutron/plugins/ml2/drivers/ovn/mech_driver/ovsdb/ovn_client.py#L2983-L3013)

## 過去の確認結果

- 広告フィルターの更新時に、別 CIDR の一時 VM `10.54.0.22/32` が両 ToR と spine に伝わり、VM 削除後に撤回されることを確認した。
- 追加 compute から両 ToR のリンクローカルまで疎通を確認した。Nova 登録と追加 compute 上のゲストの検証は未完了。

## 撤去

controller で `demo` の環境を読み込み、片方ずつ VM を削除して残る経路を確認する。ポートが残っていれば `openstack port delete` で削除してからネットワークを削除する。

```bash
source "$HOME/devstack-ovn-bgp/openrc" demo demo
openstack server delete --wait ovn-bgp-compute-vm
openstack server delete --wait ovn-bgp-vm
openstack network delete ovn-bgp-direct
openstack security group delete ovn-bgp-icmp

source "$HOME/devstack-ovn-bgp/openrc" admin admin
openstack aggregate remove host ovn-bgp-compute infra-lab-openstack-compute
openstack aggregate remove host ovn-bgp-controller infra-lab-openstack
openstack aggregate delete ovn-bgp-compute ovn-bgp-controller
openstack flavor delete ovn-bgp-ubuntu
```

片方の VM を削除した後の撤回は fabric VM で `sudo ./verify.sh withdrawn 10.53.0.23` を実行して確認できる。VM の片付け後、両 chassis と fabric VM で `sudo ./containerlab.sh destroy` を実行する。DevStack 自体の切り戻しは共通手順に従う。
