# Infra Lab

node3 上の検証専用 Linux VM で、Containerlab を使って IPv4 の宛先別経路と、IPv6 リンクローカル next hop の IPv4 デフォルトを交換する。各ラボは Dual ToR 構成で、検証対象ホストは独立した2本の L3 インターフェースを使う。ノード IP はループバックに /32 で割り当て、各種 FRR 設定には自ノードのループバック IP 以外の IP や CIDR を記述しない。ToR に接続する BGP ピアは `remote-as external` を用いたインターフェース指定の Unnumbered とし、IPv6 link-local を自動検出する。Kubernetes ラボは `kube-proxy` を廃止し、ホスト OS の FRR サービスと Cilium 間でループバック上の numbered eBGP を使う。全ラボで `net.ipv4.fib_multipath_hash_policy=1`（L4 ハッシュ）を有効化する。

| ディレクトリ | 検証内容 |
| --- | --- |
| [common](common/) | Linux VM の前提、Docker、Containerlab、共通 FRR 設定 |
| [Full L3 IP Clos](full-l3-ip-clos/) | 共有 2-Spine / 2-Leaf + NAT、デフォルトの ECMP・外向き通信・片系断 |
| [OpenStack OVN BGP Service Plugin](openstack-ovn-bgp-service-plugin/) | 2 chassis（共有 Leaf 収容）、テナント所有の flat provider network、VM 固定 IP /32 の広告・撤回 |
| [Kubernetes Cilium Full L3 BGP on the Host](k8s-cilium-full-l3-bgp-on-the-host/) | Kind + 共有 Containerlab（`infra-lab-switches` 上で完結）、Pod IP 個別 /32・ノード IP・LoadBalancer VIP の広告 |
| [OpenStack on Kubernetes + Cilium DSR L4LB](openstack-on-k8s-cilium-dsr/) | Kind 7 ノード + 専用ファブリック、OpenStack-Helm（ML2/OVN + `ovn-bgp`）、Cilium DSR（Geneve、compute ノードで終端）で無改造の VM と L7LB にクライアント IP を保持して転送 |

[共通セットアップ](common/README.md)を実行してから、各ラボの README に従う。別 VM 上の各ノードと ToR は libvirt の独立したポイントツーポイント L2 で接続し、fabric VM 側の専用 virtio NIC を ToR のネットワーク名前空間に割り当てる。

## 構成の管理

VM の管理アドレスは cloud-init、ラボ用のホストネットワークは Netplan、カーネル設定は `/etc/sysctl.d/` で管理する。FRR はノードの値と役割別の Jinja テンプレートから Ansible で生成する。Containerlab はコンテナとリンクのトポロジーを管理し、Kubernetes は kubeadm 設定とマニフェスト、OpenStack は Terraform でゲストと検証ネットワークを管理する。

OS 設定と FRR には、ファイル配置とサービス反映を各スクリプトで実装する案も比較した。3ラボで共用する FRR の生成と、ホスト側で構成変更時だけ反映する処理には Ansible を採用した。OpenStack リソースは作成順序と撤去対象を Terraform state で追跡する。

## ログイン

管理端末から `ssh -J node3 ubuntu@<管理IP>` で各 VM に入る。固定管理アドレスは [共通セットアップ](common/README.md#接続方法) を参照。

Kubernetes の操作は control plane で `sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide` を実行する。OpenStack のテナント操作はコントローラーで `source ~/devstack-ovn-bgp/openrc demo demo` を実行してから `openstack server list` を使う。

## 検証の方針

- 検証する機構と、合否を判定する観測点を先に決める。検証用ホストは BGP で IPv4 デフォルト `0.0.0.0/0` を学び、FIB で IPv6 リンクローカル next hop を確認する。宛先別経路のない IPv4 アドレスまで、デフォルトを選んでパケットが通ることも確認する。ラボの管理ネットワークは DHCP を無効にする。OpenStack のテナントサブネットは OVN BGP プラグインの要件に従って DHCP を有効にする。Kubernetes はメイン経路表を使い、OpenStack は標準プラグインに必要な VRF を使う。FRR のフィルターは許可する範囲を指定し、Service VIP 個別の値は Cilium の設定に置く。
- BGP の検証では広告と FIB を照合し、疎通試験では経路の撤回と復旧に応じて同じ通信の結果が変わることを確認する。
- 条件を満たせない場合は、使った設定と観測結果を記録する。その状態から追加設定を検証する場合は、新しい検証条件として明示する。

## ネットワーク図の方針

- 配置図は `common/README.md` に置き、物理 NIC、管理 LAN、ハイパーバイザー、ゲスト管理 NIC の接続を描く。各ラボの図はそのディレクトリの README に置き、検証に必要なノード、インターフェース、通信端点に絞る。
- Graphviz DOT で装置のポートと接続端を指定する。Kubernetes ノード、VM、ネットワーク名前空間、Pod は、その所属が検証に関わる箇所を枠で示す。物理ホスト名と管理 NIC は共通の配置図に載せる。
- 実線はリンク、実線の矢印は転送方向、青の破線は BGP やルートの受け渡し、赤い終端線は実機で確認した転送の未達を示す。管理図の青い破線はホスト内の L3 転送を示す。
- BGP Unnumbered はインターフェース名と ASN を記載する。ループバック、Pod CIDR、VIP などの試験対象はトポロジーおよび設定と照合する。実行時に生成されるインターフェース名は、名前の規則を図に記す。
- 接続と結果を更新したら、各ディレクトリの DOT ファイルを編集し、SVG を再生成して読みやすさを確認する。README は同じディレクトリの SVG を表示する。 [Graphviz のポート指定](https://graphviz.org/doc/info/shapes.html#html)

```bash
for source in */network*.dot; do
  dot -Tsvg "$source" -o "${source%.dot}.svg" || exit
done
```

## 作業レポート

fabric、Kubernetes control plane、Kubernetes worker、OpenStack controller、OpenStack compute の配置は [共通の物理構成図](common/README.md#接続方法) を参照。全3ラボ（`full-l3-ip-clos`、`k8s-cilium-full-l3-bgp-on-the-host`、`openstack-ovn-bgp-service-plugin`）で宣言的構成の冪等適用、正常時・ToR 片系断・復旧後の経路と疎通、OpenStack 追加 compute の Nova 登録および両 chassis 上のテナント VM の広告・疎通・撤回を実機で確認済み。ラボごとの検証結果と知見は各 README に記録する。
