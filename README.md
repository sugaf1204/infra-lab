# Infra Lab

node3 上の検証専用 Linux VM で、Containerlab を使って IPv4 BGP を検証する。

| ディレクトリ | 検証内容 |
| --- | --- |
| [common](common/) | Linux VM の前提、Docker、Containerlab、共通 FRR 設定 |
| [Full L3 IP Clos](full-l3-ip-clos/) | 2 spine / 2 leaf の eBGP、ECMP、リンク障害時の収束と疎通 |
| [OpenStack OVN BGP Service Plugin](openstack-ovn-bgp-service-plugin/) | Neutron の OVN BGP Service Plugin と外部ルーター間の経路広告・撤回 |
| [Kubernetes Cilium Full L3 BGP on the Host](k8s-cilium-full-l3-bgp-on-the-host/) | ToR との host BGP、native routing、Pod CIDR と LoadBalancer VIP の広告 |

[共通セットアップ](common/README.md)を実行してから、各ラボの README に従う。各ラボの管理ネットワークとデータリンクは固有の名前とアドレスを使う。データリンクは検証専用 VM 内に閉じる。
