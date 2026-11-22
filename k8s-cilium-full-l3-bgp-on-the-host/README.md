# Kubernetes Cilium Full L3 BGP on the Host

node3 の `infra-lab-fabric` VM を kubeadm で構築する単一 Kubernetes ノードとして使う。コントロールプレーンと Pod はこの VM 内で動く。Cilium は同じノード上の FRR に Pod CIDR と LoadBalancer VIP を広告する。Cilium のピアである `node-frr` は専用のネットワーク名前空間で稼働し、ToR に経路を中継する。すべての BGP セッションでインターフェース指定の eBGP Unnumbered を使う。

## 検証ネットワーク

![クライアント、ToR、単一 Kubernetes ノードの FRR、ホスト名前空間および検証 Pod のネットワーク](network.svg)

[図のソース](network.dot)

クライアント、ToR、`node-frr` とホスト名前空間を結ぶ上側の4本の実線は veth と eBGP Unnumbered を表す。Pod 側の veth 名は実行時に決まる。

| 対象 | アドレス |
| --- | --- |
| Cilium — ローカル FRR | `cilium-uplink` ↔ `eth1` |
| ローカル FRR — ToR | `eth2` ↔ `eth1` |
| ToR — 外部クライアント | `eth2` ↔ `eth1`。クライアントのループバックは `10.220.240.14/32` |
| ホスト FRR — ローカル FRR | `cilium-routes` ↔ `eth3` |
| Pod ネットワーク | `10.220.0.0/20` から kubeadm がノード用 /24 を割り当て |
| Service ネットワーク | `10.221.0.0/16` |
| LoadBalancer VIP | `10.220.250.10/32` |

外部クライアントは ToR から、Kubernetes ホストの Pod 送信用 VRF は `node-frr` から、それぞれ IPv6 next hop 付きの IPv4 デフォルトを BGP で学習する。Cilium が Pod CIDR と VIP を `node-frr` に広告し、ToR はその経路を学習する。VIP の割り当てと広告対象は Cilium リソースで管理する。FRR のフィルターは検証用アドレス範囲に適用する。

Cilium の受信経路は Linux FIB に入らないため、ホスト名前空間の FRR がデフォルトを送信 VRF に書き込む。Pod 送信元の通信は main テーブルの具体的な経路を優先し、残りは送信 VRF を使う。Kubernetes API と VM 管理通信は通常の管理ネットワークを使う。

## 準備

[共通環境](../common/README.md)を導入済みの Ubuntu 24.04 amd64 専用 VM で実行する。Kubernetes v1.34 系、Cilium 1.21.0-pre.4、containerd 2.x を使用する。インターフェース指定に対応する Cilium のプレリリースをラボに固定している。 [Cilium 1.21.0-pre.4](https://github.com/cilium/cilium/releases/tag/v1.21.0-pre.4)

Kubernetes 用 CRI は専用の containerd プロセス、ソケット、データディレクトリを使う。[kubeadm の導入手順](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) [containerd の設定](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)

Cilium ラボを以前の手順で起動済みなら、更新前のチェックアウトでそのラボの `sudo ./lab.sh down` を実行してから切り替える。

```bash
./install-tools.sh
```

## 起動と検証

```bash
sudo ./lab.sh up
sudo ./lab.sh verify
```

`up` は Containerlab を起動し、kubeadm、kube-proxy、Cilium、検証 Pod と Service を構成する。`verify` はローカル FRR と ToR が BGP で学習した Pod CIDR と VIP を FIB に持つことを確認する。クライアントと Pod 送信用 VRF の IPv4 デフォルトが `proto bgp` かつ IPv6 next hop であることを照合し、Pod IP への ping と VIP への HTTP を試す。

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n lab-probe get pod,svc -o wide
sudo docker exec clab-cilium-l3-node-frr vtysh -c 'show bgp ipv4 unicast summary'
sudo docker exec clab-cilium-l3-tor1 vtysh -c 'show bgp ipv4 unicast summary'
sudo docker exec clab-cilium-l3-tor1 vtysh -c 'show ip route bgp'
```

### 経路の撤回と復旧

検証を一度通したうえで、ローカル FRR の Cilium 向けセッションを一時停止する。Pod CIDR と VIP が両 FRR の FIB から消え、外部クライアントの経路表が変わらない状態で VIP への HTTP が失敗すれば、撤回試験は合格。

```bash
sudo docker exec clab-cilium-l3-node-frr vtysh \
  -c 'configure terminal' -c 'router bgp 65202' -c 'neighbor eth1 shutdown'
sudo docker exec clab-cilium-l3-node-frr vtysh -c 'show ip route bgp'
sudo docker exec clab-cilium-l3-tor1 vtysh -c 'show ip route bgp'
sudo docker exec clab-cilium-l3-client ip -4 route show default
sudo docker exec clab-cilium-l3-client wget -T 3 -O - http://10.220.250.10/
```

セッションを復旧し、経路の再広告と同じ疎通試験の成功を確認する。

```bash
sudo docker exec clab-cilium-l3-node-frr vtysh \
  -c 'configure terminal' -c 'router bgp 65202' -c 'no neighbor eth1 shutdown'
sudo ./lab.sh verify
```

## 撤去

`down` はこのラボの kubeadm クラスターをリセットし、このラボの転送ルール、Containerlab トポロジー、専用 CRI サービスを撤去する。パッケージと CRI のイメージキャッシュは残る。初回構築が途中で失敗した場合も `down` の後に `up` を再試行できる。

```bash
sudo ./lab.sh down
```
