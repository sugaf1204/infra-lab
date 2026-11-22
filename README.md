# Infra Lab

node3 上の検証専用 Linux VM で、Containerlab を使って IPv4 経路を交換する。各ラボは Dual ToR 構成で、検証対象ホストは独立した2本の L3 インターフェースを使う。ノード IP はループバックに /32 で割り当てる。ToR に接続する BGP ピアはインターフェース指定の Unnumbered とし、IPv6 link-local を自動検出する。Kubernetes ラボのホスト内セッションはループバック上の numbered eBGP を使う。

| ディレクトリ | 検証内容 |
| --- | --- |
| [common](common/) | Linux VM の前提、Docker、Containerlab、共通 FRR 設定 |
| [Full L3 IP Clos](full-l3-ip-clos/) | 2 spine / 2 ToR、ノード /32、デフォルトの ECMP と片系断 |
| [OpenStack OVN BGP Service Plugin](openstack-ovn-bgp-service-plugin/) | テナント所有の flat provider network、VM 固定 IP /32 の広告・撤回 |
| [Kubernetes Cilium Full L3 BGP on the Host](k8s-cilium-full-l3-bgp-on-the-host/) | kubeadm 単一ノード、Pod IP 個別 /32・ノード IP・LoadBalancer VIP の広告 |

[共通セットアップ](common/README.md)を実行してから、各ラボの README に従う。各ラボの管理ネットワークとデータリンクは固有の名前とアドレスを使う。データリンクは検証専用 VM 内に閉じる。

## 検証の方針

- 検証する機構と、合否を判定する観測点を先に決める。検証用ホストはデフォルトを含む IPv4 経路を BGP で学習し、FIB の IPv6 next hop を確認する。FRR のフィルターは許可する範囲を指定し、Service VIP 個別の値は Cilium の設定に置く。
- BGP の検証では広告と FIB を照合し、疎通試験では経路の撤回と復旧に応じて同じ通信の結果が変わることを確認する。
- 条件を満たせない場合は、使った設定と観測結果を記録する。その状態から追加設定を検証する場合は、新しい検証条件として明示する。

## ネットワーク図の方針

- 配置図は `common/README.md` に置き、物理 NIC、管理 LAN、ハイパーバイザー、ゲスト管理 NIC の接続を描く。各ラボの図はそのディレクトリの README に置き、検証に必要なノード、インターフェース、通信端点に絞る。
- Graphviz DOT で装置のポートと接続端を指定する。Kubernetes ノード、VM、ネットワーク名前空間、Pod は、その所属が検証に関わる箇所を枠で示す。物理ホスト名と管理 NIC は共通の配置図に載せる。
- 実線はリンク、実線の矢印は転送方向、青の破線は BGP やルートの受け渡し、赤い終端線は実機で確認した転送の未達を示す。管理図の青い破線はホスト内の L3 転送を示す。
- BGP Unnumbered はインターフェース名と ASN を記載する。ループバック、Pod CIDR、VIP などの試験対象はトポロジーおよび設定と照合する。実行時に生成されるインターフェース名は、名前の規則を図に記す。
- 接続と結果を更新したら、各ディレクトリの `network.dot` を編集し、SVG を再生成して読みやすさを確認する。README は同じディレクトリの SVG を表示する。 [Graphviz のポート指定](https://graphviz.org/doc/info/shapes.html#html)

```bash
for source in */network.dot; do
  dot -Tsvg "$source" -o "${source%.dot}.svg" || exit
done
```

## 作業レポート

node3 に libvirt の検証専用 VM を2台作成し、Containerlab で3つの IPv4 BGP ラボを起動した。以下は node3 で実行した検証の記録。

| ラボ | 検証結果 |
| --- | --- |
| Full L3 IP Clos | **合格**。8本の Unnumbered セッション、両ホストの IPv4 デフォルトと両 spine のノード /32 の ECMP を確認した。両方の片系断で経路は残る ToR に収束し、ホスト間の双方向 ping に成功した。 |
| OpenStack OVN BGP Service Plugin | **合格**。`demo` 所有の内部 flat ネットワークで、CirrOS の固定 IP `10.53.0.22/32` を両 ToR で学習した。両方の片系断で chassis のループバックと VM 固定 IP への ping に成功した。VM 削除で /32 が撤回され、再作成で再広告された。 |
| Kubernetes Cilium Full L3 BGP on the Host | **合格**。4本の Unnumbered セッションとホスト内の numbered eBGP で、ノード IP・個別 Pod /32・VIP を両 ToR で学習した。両方の片系断でノードと Pod への ping、VIP への HTTP に成功した。一時 Pod の作成・削除でその /32 の広告・撤回を確認し、Cilium の広告設定を外すと VIP も両 ToR から撤回されることを確認した。 |

両 VM の稼働中に、node3 の利用可能メモリは **約5.0 GiB**、スワップ入出力カウンターはどちらも **0** だった。既存の CAPI VM は計測時に停止していた。物理構成と VM 管理手順は [共通セットアップ](common/README.md#物理ホストと-vm-の配置)、各ラボの論理構成は冒頭のディレクトリ一覧を参照。
