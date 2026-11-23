# Kubernetes Cilium Full L3 BGP on the Host

kubeadm の control plane と worker を別々の VM で動かす。`kube-proxy` は廃止し、Cilium の `kubeProxyReplacement: true` で Service 転送を行う。両ノードを2台の ToR に接続し、ノード IP はそれぞれのループバックに IPv4 /32 で1つ割り当てる。ホスト FRR は各ノード OS の systemd サービス（`frr` パッケージ）として直接動かし、Kubernetes ノード上には Docker や余分なブリッジ（`docker0` 等）を作成しない。各ノードの Cilium とホスト FRR の間は Cilium の `127.0.0.2` から FRR の `127.0.0.1` への接続で numbered eBGP を張る。ホスト FRR 側で `local-as 65200 no-prepend replace-as` を設定することで、全ノード共通の1つの `CiliumBGPClusterConfig` でピアを張る。

## 実機検証結果（2026-11-23）

Ubuntu 24.04.5 の control plane（`infra-lab-k8s-control`）と worker（`infra-lab-k8s-worker`）、および fabric VM（`infra-lab-switches`、Containerlab 0.83.0 / FRR 10.4.1）で全検証を通過した。

- **冪等性・ホスト構成**: 両ノードで `host.yml` の Ansible 再実行は `changed=0 failed=0`、`lab.sh up` の再実行も正常完了した。両ノードの `lo` はそれぞれ `10.220.255.10/32`・`10.220.255.11/32`、IPv4 main table のデフォルト経路は IPv6 リンクローカル 2-way ECMP（`src` 自ノード IP）、VRF・ブリッジ（`docker0` 等）は不在、`net.ipv4.fib_multipath_hash_policy=1` を確認した。
- **FRR と Cilium の実機知見**:
  - Ubuntu 24.04 標準の FRR 8.4.4 では Cilium が作成する `proto kernel` の Pod `/32` ルートが zebra に取り込まれなかったため、`install-tools.sh` で FRRouting 公式リポジトリ（`frr-10`、検証時は `10.7.1`）を導入する構成とした。これにより不要な `/32` の漏洩なく Node IP・Pod `/32`・VIP `/32` のみが BGP 広告されることを確認した。
  - BGP Unnumbered 環境では `k8s-tor1` / `k8s-tor2` に IPv4 アドレスが付かないため、Cilium の `kubeProxyReplacement: true` で BPF を正しくアタッチするには `cilium-values.yaml` に `devices: "k8s-tor+,lo"` と `nodePort.directRoutingDevice: "lo"` の明示が必要だった。
- **疎通・障害復旧**:
  - control plane の `sudo ./lab.sh verify`（`kube-proxy` DaemonSet 不在、ノード間・外部クライアント疎通、両 Pod → 外部クライアント疎通、Pod 間双方向疎通）が終了コード 0 で通過した。
  - worker の `sudo ./lab.sh verify-node`（ローカル BGP 3セッション Established、デフォルト ECMP、VRF/ブリッジ不在、疎通）が終了コード 0 で通過した。
  - fabric VM の `sudo ./lab.sh verify-fabric --failover`（両 ToR での VIP `10.220.250.10/32` 2-way ECMP、正常時・`tor1` 片系断・復旧・`tor2` 片系断・復旧での両ノード ping と `http://10.220.250.10/` の `probe` 応答）が終了コード 0 で通過した。

## 検証ネットワーク

![Fabric VM と同じ階層にある2台の Kubernetes VM を Dual ToR に接続する](network.svg)

[図のソース](network.dot)

control plane と worker はそれぞれ独立した VM。各ノードは `k8s-tor1` と `k8s-tor2` を独立した L3 インターフェースとして使う。両リンクで `remote-as external` を用いたインターフェース指定の eBGP Unnumbered を張る。ノードのループバックは control plane が `10.220.255.10/32`、worker が `10.220.255.11/32`。

- Cilium は同じノードの FRR に `127.0.0.2` → `127.0.0.1` でピアを張り、LoadBalancer IP を広告する。ホスト FRR は Node IP と Cilium がカーネルに設定した Pod /32 を両 ToR に広告する。FRR 設定には自ノードのループバック IP 以外の IP や CIDR を記述しない。
- ToR は各ノードに IPv4 デフォルトのみを広告し、ノードの Node IP、Pod IP、VIP をホストルート (/32) として受け付ける。ToR は特定の Node IP や Pod CIDR に依存しない。ノードのメイン経路表で `0.0.0.0/0` の next hop が IPv6 リンクローカルになり、対向ノードや外部クライアント `10.220.240.14` をデフォルト経路で引くことを確認する。VRF、余分なブリッジ、静的デフォルト、DHCP、kube-proxy は使わない。また全ノード・ToR で `net.ipv4.fib_multipath_hash_policy=1`（L4 ハッシュ）を有効化する。

## 環境に入る

管理端末から fabric は `ssh -J node3 ubuntu@192.168.122.250`、control plane は `ssh -J node3 ubuntu@192.168.122.219`、worker は `ssh -J node3 ubuntu@192.168.122.7`。 [共通セットアップ](../common/README.md)

## 構築と検証

[共通セットアップ](../common/README.md)で3台の VM とデータリンクを用意する。Docker と Containerlab の導入は fabric VM のみでよい。両 Kubernetes ノードで `./install-tools.sh` を実行して `containerd`、`frr`、`kubelet`、`kubeadm`、`kubectl`、`helm` を導入する。構築時には kubeadm・Cilium・検証 Pod 用イメージと Helm チャートを管理経由で取得できるようにする。ラボは Kubernetes v1.34 系、Cilium 1.21.0-pre.4、containerd 2.x を使う。 [Cilium 1.21.0-pre.4](https://github.com/cilium/cilium/releases/tag/v1.21.0-pre.4)

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

control plane で `sudo ./lab.sh verify` を実行し、`kube-proxy` 不在・Pod 間の双方向疎通・両 Pod から外部クライアントへデフォルト経路を使った通信を確認する。worker の `sudo ./lab.sh verify-node` は、ローカルの BGP セッション、FIB、VRF/ブリッジ不在を確認する。fabric の `sudo ./lab.sh verify-fabric --failover` は各 ToR を片方ずつ停止して、ToR 上の Service VIP 向け 2-way ECMP とクライアントから両ノード・Service VIP への疎通を確認する。

## 撤去

worker、control plane の順に `sudo ./lab.sh down` を実行する。最後に fabric で `sudo ./lab.sh fabric-down` を実行する。
