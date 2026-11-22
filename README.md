# Infra Lab

node3 上の検証専用 Linux VM で、Containerlab を使って IPv4 BGP を検証する。

| ディレクトリ | 検証内容 |
| --- | --- |
| [common](common/) | Linux VM の前提、Docker、Containerlab、共通 FRR 設定 |
| [Full L3 IP Clos](full-l3-ip-clos/) | 2 spine / 2 leaf の eBGP、ECMP、リンク障害時の収束と疎通 |
| [OpenStack OVN BGP Service Plugin](openstack-ovn-bgp-service-plugin/) | Neutron の OVN BGP Service Plugin と外部ルーター間の経路広告・撤回 |
| [Kubernetes Cilium Full L3 BGP on the Host](k8s-cilium-full-l3-bgp-on-the-host/) | kubeadm 単一ノードと ToR 間の host BGP、Pod CIDR と LoadBalancer VIP の広告 |

[共通セットアップ](common/README.md)を実行してから、各ラボの README に従う。各ラボの管理ネットワークとデータリンクは固有の名前とアドレスを使う。データリンクは検証専用 VM 内に閉じる。

## 作業レポート

node3 に libvirt の検証専用 VM を2台作成し、Containerlab で3つの IPv4 BGP ラボを起動した。以下は node3 で実行した検証と、その後の構成変更の記録。

| ラボ | 検証結果 |
| --- | --- |
| Full L3 IP Clos | **合格**。4本の eBGP セッションと両 leaf の2経路 ECMP を確認。leaf1–spine1 断で両 leaf が spine2 に収束し、復旧後は2経路に戻った。各段階でホスト間の双方向 ping に成功。 |
| OpenStack OVN BGP Service Plugin | **テナント固定 IP に変更**。予備検証では固定 IP の /32 が spine の Linux FIB に入り、ICMP 応答は得られなかった。現行手順は固定 IP の広告・撤回・再広告と疎通を確認する。 |
| Kubernetes Cilium Full L3 BGP on the Host | **kubeadm 単一ノード構成に変更**。外部クライアントからの Pod 疎通と LoadBalancer VIP への HTTP、BGP 停止時の撤回と復旧を検証する。 |

両 VM の稼働中に、node3 の利用可能メモリは **6.3 GiB**、スワップ入出力カウンターはどちらも **0** だった。既存の CAPI VM は計測時に停止していた。物理構成と VM 管理手順は [共通セットアップ](common/README.md#物理ホストと-vm-の配置)、各ラボの論理構成は冒頭のディレクトリ一覧を参照。
