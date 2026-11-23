# Kubernetes Cilium Full L3 BGP on the Host

Kind（Kubernetes in Docker）の 2 ノードクラスタ（`cilium-l3-control-plane` / `cilium-l3-worker`）を、`infra-lab-switches` 上の共有ファブリック（[../full-l3-ip-clos](../full-l3-ip-clos/) の共有 Dual-ToR `leaf1`/`leaf2` + Spine + NAT）に収容して Full L3 IP CLOS + BGP on the Host を検証する。`kube-proxy` は廃止（`kubeProxyMode: none` + Cilium `kubeProxyReplacement: true`）する。

Cilium 公式の `contrib/containerlab/service` 構成を参考に、各 Kind ノードと同じネットワーク名前空間（`network-mode: container:<kind-node>`）で FRR 10.4.1 コンテナ（`node0` / `node1`）を動かし、共有トポロジー [../full-l3-ip-clos/topology.clab.yml](../full-l3-ip-clos/topology.clab.yml) に全ノードとリンクを一元記述する。

## 実機検証結果（2026-11-24）

`infra-lab-switches`（Ubuntu 24.04.5、4 vCPU / 6 GiB、Docker 29.1.3 / Containerlab 0.83.0 / Kind v0.27.0 / FRR 10.4.1 / Cilium 1.21.0-pre.4）で共有ファブリック上に展開し、全検証を通過した。

- **疎通・外向き通信・NAT 非流出・障害復旧**: `sudo ./verify.sh --failover` が終了コード 0 で通過した。
  - `kube-proxy` DaemonSet 不在、両ノードの `lo` `/32`（`10.220.255.10/32`・`10.220.255.11/32`）、BGP 3 セッション（`k8s-tor1` / `k8s-tor2` / Cilium `127.0.0.2`）Established、IPv4 デフォルトの IPv6 リンクローカル 2-way ECMP、および NAT IP（`100.64.0.`）の非流出を確認。
  - ノード間・Pod 間双方向・両ノード＆両 Pod → 外部（`1.1.1.1`、NAT 経由）および `host1`（`10.211.1.2`）への疎通を確認。
  - 共有 ToR（`leaf1`/`leaf2`）での LoadBalancer VIP（`10.220.250.10/32`）2-way ECMP、正常時・`leaf1` 片系断・復旧・`leaf2` 片系断・復旧のすべてで、`host1` からの両ノード ping と `http://10.220.250.10/` の `probe` 応答を確認。
- **実機知見**:
  - BGP Unnumbered 環境で Cilium KPR を有効にするため、[cilium-values.yaml](cilium-values.yaml) に `devices: "k8s-tor+,lo"`・`nodePort.directRoutingDevice: "lo"`・`socketLB.enabled: false` を設定し、[../full-l3-ip-clos/topology.clab.yml](../full-l3-ip-clos/topology.clab.yml) でデータ NIC の `rp_filter=0` と `fib_multipath_hash_policy=1` を有効化している。

## 構成ファイル

- [cluster.yaml](cluster.yaml): Kind 2 ノードクラスタ定義（`disableDefaultCNI: true`, `kubeProxyMode: none`, 各ノード `node-ip`）
- [../full-l3-ip-clos/topology.clab.yml](../full-l3-ip-clos/topology.clab.yml) / [../full-l3-ip-clos/nodes.yml](../full-l3-ip-clos/nodes.yml): 共有ファブリックと Kind ノード相乗り FRR（`node0`/`node1`）の定義
- [cilium-values.yaml](cilium-values.yaml) / [bgp.yaml](bgp.yaml) / [probes.yaml](probes.yaml): Cilium・BGP Control Plane・検証ワークロード定義

## 構築と検証

[共通セットアップ](../common/README.md)（Docker / Containerlab / Ansible / FRR 10.4.1 イメージ）後、このディレクトリで `./install-tools.sh` を実行して `kind`・`kubectl`・`helm` を導入する。

```bash
sudo ./lab.sh up
sudo ./verify.sh
sudo ./verify.sh --failover
```

## 撤去

```bash
sudo ./lab.sh down
```
