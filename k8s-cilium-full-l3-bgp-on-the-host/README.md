# Kubernetes Cilium Full L3 BGP on the Host

kubeadm の control plane と worker を別々の VM で動かす。両ノードを2台の ToR に接続し、ノード IP はそれぞれのループバックに IPv4 /32 で1つ割り当てる。各ノードの Cilium とホスト FRR の間は Cilium の `127.0.0.2` から FRR の `127.0.0.1` への接続で numbered eBGP を張る。

## 検証ネットワーク

![Fabric VM と同じ階層にある2台の Kubernetes VM を Dual ToR に接続する](network.svg)

[図のソース](network.dot)

control plane と worker はそれぞれ独立した VM。各ノードは `k8s-tor1` と `k8s-tor2` を独立した L3 インターフェースとして使う。両リンクでインターフェース指定の eBGP Unnumbered を張る。ノードのループバックは control plane が `10.220.255.10/32`、worker が `10.220.255.11/32`。

- Cilium は同じノードの FRR に `127.0.0.2` → `127.0.0.1` でピアを張り、LoadBalancer IP を広告する。ホスト FRR は Node IP と Cilium がカーネルに設定した Pod /32 を両 ToR に広告する。
- ToR は各ノードに IPv4 デフォルトのみを広告し、ノードの Node IP、Pod IP、VIP をホストルート (/32) として受け付ける。ToR は特定の Node IP や Pod CIDR に依存しない。ノードのメイン経路表で `0.0.0.0/0` の next hop が IPv6 リンクローカルになり、対向ノードや外部クライアント `10.220.240.14` をデフォルト経路で引くことを確認する。VRF、静的デフォルト、DHCP は使わない。

## 環境に入る

管理端末から fabric は `ssh -J node3 ubuntu@192.168.122.250`、control plane は `ssh -J node3 ubuntu@192.168.122.219`、worker は `ssh -J node3 ubuntu@192.168.122.7`。 [共通セットアップ](../common/README.md)

## 構築と検証

[共通セットアップ](../common/README.md)で3台の VM とデータリンクを用意する。両 Kubernetes ノードで `./install-tools.sh` を実行する。構築時には kubeadm・Cilium・検証 Pod 用イメージと Helm チャートを管理経由で取得できるようにする。ラボは Kubernetes v1.34 系、Cilium 1.21.0-pre.4、containerd 2.x を使う。 [Cilium 1.21.0-pre.4](https://github.com/cilium/cilium/releases/tag/v1.21.0-pre.4)

```bash
# fabric
sudo ./lab.sh fabric-up
# control plane
sudo ./lab.sh up
```

管理端末で join 設定を標準入力で worker に渡す。両ノードに同じリポジトリを `~/infra-lab` に配置した例。

```bash
set -o pipefail
ssh -J node3 ubuntu@192.168.122.219   'cd ~/infra-lab/k8s-cilium-full-l3-bgp-on-the-host && sudo -n ./lab.sh join-config' |
ssh -J node3 ubuntu@192.168.122.7   'cd ~/infra-lab/k8s-cilium-full-l3-bgp-on-the-host && sudo -n ./lab.sh join'
```

control plane で `sudo ./lab.sh verify` を実行し、Pod 間の双方向疎通と、両 Pod から外部クライアントへデフォルト経路を使った通信を確認する。worker の `sudo ./lab.sh verify-node` は、ローカルの BGP セッションと FIB を確認する。fabric の `sudo ./lab.sh verify-fabric --failover` は各 ToR を片方ずつ停止して、クライアントから両ノードと Service VIP への疎通を確認する。

## 撤去

worker、control plane の順に `sudo ./lab.sh down` を実行する。最後に fabric で `sudo ./lab.sh fabric-down` を実行する。
