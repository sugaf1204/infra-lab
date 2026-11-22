# Infra Lab

node3 上の検証専用 Linux VM で、Containerlab を使って IPv4 経路を交換する。BGP ピアはすべてインターフェース指定の Unnumbered とし、IPv6 link-local を自動検出する。

| ディレクトリ | 検証内容 |
| --- | --- |
| [common](common/) | Linux VM の前提、Docker、Containerlab、共通 FRR 設定 |
| [Full L3 IP Clos](full-l3-ip-clos/) | 2 spine / 2 leaf の eBGP、ECMP、リンク障害時の収束と疎通 |
| [OpenStack OVN BGP Service Plugin](openstack-ovn-bgp-service-plugin/) | Neutron の OVN BGP Service Plugin と外部ルーター間の経路広告・撤回 |
| [Kubernetes Cilium Full L3 BGP on the Host](k8s-cilium-full-l3-bgp-on-the-host/) | kubeadm 単一ノードの Cilium → ローカル FRR → ToR、Pod CIDR と LoadBalancer VIP の広告 |

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
| Full L3 IP Clos | **合格**。6本の eBGP Unnumbered セッション、両ホストが BGP で学習した IPv4 デフォルトと IPv6 next hop、両 leaf の2経路 ECMP を確認。leaf1–spine1 断で両 leaf が spine2 に収束し、復旧後は2経路に戻った。各段階でホスト間の双方向 ping に成功。 |
| OpenStack OVN BGP Service Plugin | **経路交換は合格、疎通は未達**。chassis–leaf と leaf–spine の2本の Unnumbered セッションでテナント固定 IP `10.53.0.22/32` の広告・撤回・再広告を確認した。chassis は IPv6 next hop 付きの IPv4 デフォルトを BGP で学習した。spine からの ICMP は chassis の uplink に到着したが、CirrOS の TAP には届かなかった。 |
| Kubernetes Cilium Full L3 BGP on the Host | **合格**。4本の Unnumbered セッションを確認。クライアントと Pod 送信用 VRF は IPv6 next hop 付きの IPv4 デフォルトを BGP で学習した。Pod CIDR と VIP の撤回で、クライアントのデフォルト経路が残っていても VIP 宛て HTTP が失敗し、再広告で Pod 宛て ping と HTTP が復旧した。ホスト FRR のピアを止めると VRF のデフォルト経路も消え、ピアの復旧で戻った。 |

両 VM の稼働中に、node3 の利用可能メモリは **約5.5 GiB**、スワップ入出力カウンターはどちらも **0** だった。既存の CAPI VM は計測時に停止していた。物理構成と VM 管理手順は [共通セットアップ](common/README.md#物理ホストと-vm-の配置)、各ラボの論理構成は冒頭のディレクトリ一覧を参照。
