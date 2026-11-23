# Kubernetes Cilium Full L3 BGP on the Host

kubeadm の control plane と worker を別々の VM で動かす。両ノードを2台の ToR に接続し、ノード IP はそれぞれのループバックに IPv4 /32 で1つ割り当てる。各ノードの Cilium とホスト FRR の間は Cilium の `127.0.0.2` から FRR の `127.0.0.1` への接続で numbered eBGP を張る。

## 検証ネットワーク

![Dual ToR と control plane・worker の Cilium ラボ](network.svg)

[図のソース](network.dot)

| 接続 | インターフェース |
| --- | --- |
| control plane → ToR1 / ToR2 | `cilium-tor1` ↔ `tor1:eth1`、`cilium-tor2` ↔ `tor2:eth1` |
| worker → ToR1 / ToR2 | `k8s-tor1` ↔ `tor1:eth3`、`k8s-tor2` ↔ `tor2:eth3`。各リンクに専用の L2 区間を使い、fabric VM の NIC に ToR を MACVLAN で接続する |
| クライアント → ToR1 / ToR2 | `client:eth1` ↔ `tor1:eth2`、`client:eth2` ↔ `tor2:eth2` |
| control plane の Node IP と API | `10.220.255.10/32`、API は TCP 6443 |
| worker の Node IP | `10.220.255.11/32` |

- ToR 接続はすべて独立したインターフェースを使う eBGP Unnumbered。検証データパスのデフォルト経路は BGP から学習する `::/0` で、ネクストホップは IPv6 リンクローカル。IPv4 は Node、Pod、VIP、クライアントの各 /32 を BGP で交換する。VM の管理 NIC は libvirt 管理ネットワークを使う。
- Cilium が Service VIP をホスト FRR に広告する。FRR は `bgp listen range 127.0.0.2/32` と `update-source lo` で IPv4 ローカルピアを受け、VIP の BGP next hop を自ホストの Node IP に設定する。ローカル next hop の許可は外部ピアから分離した default VRF に置く。 [Cilium BGP の公式設定例](https://docs.cilium.io/en/latest/network/bgp-control-plane/bgp-control-plane-configuration/#bgp-cluster-configuration)
- Cilium の `endpointRoutes.enabled` は Pod ごとの /32 を Linux に追加する。ホスト FRR はその /32 と Node IP を再配布する。検証用 DaemonSet が両ノードに Pod を1つずつ配置する。 [Cilium の Pod 経路実装](https://github.com/cilium/cilium/blob/v1.21.0-pre.4/pkg/datapath/loader/endpoint.go#L239-L323)

## 環境に入る

node3 の libvirt DHCP リースから、現在の管理 IP を確認する。

```bash
lab_vm_ip() {
  ssh node3 sudo virsh domifaddr "$1" --source lease |
    awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }'
}
control_ip=$(lab_vm_ip infra-lab-fabric)
worker_ip=$(lab_vm_ip infra-lab-k8s-worker)
ssh -J node3 "ubuntu@$control_ip"
ssh -J node3 "ubuntu@$worker_ip"
```

クラスタ操作は control plane で行う。

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n lab-probe get pods,svc -o wide
sudo docker exec clab-cilium-l3-tor1 vtysh -c 'show bgp ipv4 unicast summary' -c 'show bgp ipv6 unicast'
```

各ノードでは `ip -6 route show table 220` と `sudo docker exec clab-cilium-l3-host-frr vtysh -c 'show bgp vrf cilium-egress summary'` を使える。

## 構築と検証

[共通セットアップ](../common/README.md)で Ubuntu 24.04 amd64 の `infra-lab-fabric` と `infra-lab-k8s-worker` を用意する。両 VM の `k8s-tor1` と `k8s-tor2` は、共通セットアップで ToR ごとの専用 L2 区間に接続する。ラボは Kubernetes v1.34 系、Cilium 1.21.0-pre.4、containerd 2.x を使う。 [Cilium 1.21.0-pre.4](https://github.com/cilium/cilium/releases/tag/v1.21.0-pre.4)

単一ノード環境から移行する場合は、旧チェックアウトで `sudo ./lab.sh down` を実行してから切り替える。両 VM でラボディレクトリに入り、`./install-tools.sh` を実行する。control plane で次を実行する。

```bash
sudo ./lab.sh up
```

管理端末で次を実行する。両 VM に同じリポジトリを `~/infra-lab-dual` に配置した例。join トークンはこの SSH パイプ経由で worker に渡し、20分で失効する。

```bash
set -o pipefail
ssh -J node3 "ubuntu@$control_ip" \
  'cd ~/infra-lab-dual/k8s-cilium-full-l3-bgp-on-the-host && sudo -n ./lab.sh join-config' |
ssh -J node3 "ubuntu@$worker_ip" \
  'cd ~/infra-lab-dual/k8s-cilium-full-l3-bgp-on-the-host && sudo -n ./lab.sh join'
```

control plane で `sudo ./lab.sh verify --failover`、worker で `sudo ./lab.sh verify-node` を実行する。前者は両ノードの Ready 状態、両 ToR の Node・Pod /32 と VIP、Pod 間 ping、クライアントから両ノード・Pod への ping、VIP 宛ての HTTP を確認する。片系断試験では ToR に接続した3ポートを1台ずつ停止し、残る ToR で同じ疎通を確認する。後者は worker の BGP セッション、`::/0`、他ノードとクライアントへの /32 を確認する。API と kubelet の TCP ソケットはデータ VRF からの Node IP 宛て通信を受ける。ラボが設定する `tcp_l3mdev_accept` は `down` で元の値に戻す。Ubuntu の systemd-networkd が再起動時に BGP 経路とポリシールールを削除しないよう、ラボ用の drop-in を VM 内に配置する。 [networkd.conf](https://www.freedesktop.org/software/systemd/man/255/networkd.conf.html#ManageForeignRoutingPolicyRules=)

## 撤去

最初に worker 側で `sudo ./lab.sh down` を実行し、次に control plane 側で同じコマンドを実行する。`down` は kubeadm、ラボ専用ループバック IP、経路ポリシー、Containerlab のリソース、専用 CRI サービスを撤去する。共通セットアップで用意した仮想 NIC と管理ネットワークは VM 側の構成として扱う。
