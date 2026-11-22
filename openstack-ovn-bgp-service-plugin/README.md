# OpenStack OVN BGP Service Plugin

Neutron 2026.2 の組み込み `ovn-bgp` service plugin と OVN Neutron Agent の `ovn-bgp` 拡張を有効にし、spine から CirrOS VM の固定 IP へ直接到達できるか、テナントのホスト経路を広告・撤回して検証する。Floating IP は割り当てない。OVN が Linux VRF のテーブル 42 に置いた経路を chassis の FRR が取得し、leaf、spine の順に eBGP で伝える。leaf から受信するデフォルト経路はテーブル 10 に入れ、OVN の戻り経路に使う。

## 論理構成

```mermaid
flowchart TB
    subgraph HOST["node3 内の libvirt VM · infra-lab-openstack"]
        subgraph CLAB["Containerlab コンテナ"]
            SPINE["spine · AS65233<br/>検証元 203.0.113.10"]
            LEAF["leaf · AS65232"]
            SPINE ---|"eBGP · 192.0.2.0/31"| LEAF
        end
        subgraph CHASSIS["OpenStack chassis"]
            FRR["chassis FRR · AS65231"]
            UPLINK["OVS br-bgp-0"]
            VRF["Linux VRF · テーブル 42"]
            ROUTER["bgp-lr-main / テナント Geneve ネットワーク"]
            VRF -->|"固定 IP 10.53.0.22/32"| FRR
            UPLINK --> ROUTER
        end
        subgraph GUEST["Nova が起動する CirrOS VM"]
            VNIC["テナント NIC · 10.53.0.22"]
        end
        LEAF ---|"veth · ovnbgp-uplink"| UPLINK
        FRR -.->|"eBGP unnumbered · /32 広告"| LEAF
        ROUTER -->|"OVS / TAP · 固定 IP 宛の検証経路"| VNIC
    end
```

## 構築

node3 上のこのラボ専用 Ubuntu 26.04 amd64 VM で実行する。DevStack は VM のパッケージ、サービス、ファイアウォールを変更するため、セットアップ前の状態を残したい場合は VM のスナップショットを取得する。node3 の割り当ては 8 vCPU、16 GiB メモリ、120 GiB ディスク。CirrOS は QEMU で起動するため、ネストされた KVM は不要。パッケージ、Git リポジトリ、CirrOS イメージ、コンテナイメージへのアクセスが必要。

[共通手順](../common/README.md)で Docker と containerlab を用意する。以下は専用 VM の sudo が使える管理ユーザーで実行する。DevStack は非 root の sudo パスワード不要ユーザーで実行する。

```bash
./setup-devstack.sh
```

スクリプトは専用パスワードを生成し、DevStack の `local.conf` にアクセス権 0600 で保存する。

DevStack が成功したら、このディレクトリに戻って実行する。

```bash
sudo containerlab deploy -t topology.clab.yml
sudo ovs-vsctl --may-exist add-br br-ex
sudo ovs-vsctl --may-exist add-br br-bgp-0
sudo ovs-vsctl --may-exist add-port br-bgp-0 ovnbgp-uplink
sudo ip link set br-bgp-0 up
sudo ip link set br-ex up
sudo ovs-vsctl set Open_vSwitch . external_ids:ovn-bridge-mappings=public:br-ex,br-bgp-0:br-bgp-0

sudo sed -i 's/^bgpd=no$/bgpd=yes/' /etc/frr/daemons
sudo install -o frr -g frr -m 640 frr/chassis.conf /etc/frr/frr.conf
sudo systemctl restart frr
```

## テナント固定 IP の検証

専用 VM で DevStack の `openrc` を読み込む。以下のコマンドは空のラボにリソースを作成する。

```bash
source "$HOME/devstack-ovn-bgp/openrc" admin admin
openstack network agent list
openstack extension list --network | grep ovn-bgp

openstack network create --external --provider-physical-network public \
  --provider-network-type flat ovn-bgp-public
openstack subnet create --network ovn-bgp-public \
  --subnet-range 198.51.100.0/24 --gateway 198.51.100.1 \
  --allocation-pool start=198.51.100.50,end=198.51.100.150 --no-dhcp ovn-bgp-public-v4

openstack network create ovn-bgp-tenant
openstack subnet create --network ovn-bgp-tenant \
  --subnet-range 10.53.0.0/24 ovn-bgp-tenant-v4
openstack router create ovn-bgp-router
openstack router add subnet ovn-bgp-router ovn-bgp-tenant-v4
openstack router set --external-gateway ovn-bgp-public --disable-snat ovn-bgp-router

openstack security group create ovn-bgp-icmp
openstack security group rule create --ingress --protocol icmp \
  --remote-ip 203.0.113.10/32 ovn-bgp-icmp
openstack flavor create --vcpus 1 --ram 512 --disk 1 ovn-bgp-tiny
openstack port create --network ovn-bgp-tenant \
  --fixed-ip subnet=ovn-bgp-tenant-v4,ip-address=10.53.0.22 \
  --security-group ovn-bgp-icmp ovn-bgp-vm-port
openstack server create --wait --image cirros-0.6.3-x86_64-disk \
  --flavor ovn-bgp-tiny --port ovn-bgp-vm-port ovn-bgp-vm
openstack subnet set --leak-routes ovn-bgp-tenant-v4
```

Route leaking の有効化には、Geneve サブネットが外部ゲートウェイ付きの Neutron ルーターに接続されている必要がある。外部ゲートウェイはこの前提を満たすために作成する。FRR はテナント範囲の /32 だけをファブリックに広告する。

```bash
sudo ovn-nbctl lr-list
sudo ovn-sbctl list Advertised_Route
sudo ip route show table 42
sudo ip route show table 10
sudo ovs-ofctl dump-flows br-bgp-0
sudo ./verify.sh advertised
sudo ./verify.sh reachable
```

`advertised` は固定 IP `10.53.0.22/32` をテーブル 42、spine の BGP RIB と Linux FIB で照合する。`reachable` は spine から CirrOS の固定 IP に直接 ping する。テーブル 10 では leaf からのデフォルト経路を確認できる。

Route leaking を無効化して広告を撤回し、再び有効化して再広告を確認する。CirrOS と固定 IP は保持する。

```bash
openstack subnet set --no-leak-routes ovn-bgp-tenant-v4
sudo ./verify.sh withdrawn
openstack subnet set --leak-routes ovn-bgp-tenant-v4
sudo ./verify.sh advertised
```

## 片付けと切り戻し

OpenStack を保持する場合は、専用 VM 内で次の順でリソースを片付ける。

```bash
openstack subnet set --no-leak-routes ovn-bgp-tenant-v4
openstack server delete --wait ovn-bgp-vm
openstack port delete ovn-bgp-vm-port
openstack router remove subnet ovn-bgp-router ovn-bgp-tenant-v4
openstack router unset --external-gateway ovn-bgp-router
openstack router delete ovn-bgp-router
openstack network delete ovn-bgp-tenant
openstack network delete ovn-bgp-public
openstack security group delete ovn-bgp-icmp
openstack flavor delete ovn-bgp-tiny

sudo ovs-vsctl --if-exists del-port br-bgp-0 ovnbgp-uplink
sudo ovs-vsctl --if-exists del-br br-bgp-0
sudo containerlab destroy -t topology.clab.yml --cleanup
```

DevStack や chassis FRR の導入を含めて切り戻す場合は、専用 VM を構築前のスナップショットに戻すか、共通手順で専用 VM を作り直す。再実行前に VM 内の管理アドレスとルートを確認する。

- [Neutron 2026.2 の OVN BGP service plugin](https://docs.openstack.org/neutron/2026.2/admin/ovn/bgp.html)
- [Neutron 2026.2 の BGP 統合テスト](https://docs.openstack.org/neutron/2026.2/ovn/bgp_tempest_job.html)
- [統合テストのバージョン固定と DevStack 設定](https://github.com/openstack/neutron/blob/stable/2026.2/zuul.d/tempest-multinode-bgp.yaml)
