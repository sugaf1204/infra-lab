# Kubernetes Cilium Full L3 BGP on the Host

Kind（Kubernetes in Docker）の 2 ノードクラスタ（`cilium-l3-control-plane` / `cilium-l3-worker`）と Containerlab の FRR 10.4.1 コンテナを組み合わせ、1 台の専用 Linux VM 上で Full L3 IP CLOS + BGP on the Host を検証する。`kube-proxy` は廃止（`kubeProxyMode: none` + Cilium `kubeProxyReplacement: true`）する。

Cilium 公式の `contrib/containerlab/service` 構成を参考に、各 Kind ノードと同じネットワーク名前空間（`network-mode: container:<kind-node>`）で FRR 10.4.1 コンテナ（`node0` / `node1`）を動かし、ToR（`tor1` / `tor2`）および外部クライアント（`client`）を含めた全 5 ノード・全 6 リンクを [topology.clab.yml](topology.clab.yml) に一元記述する。

## 実機検証結果（2026-11-24）

Ubuntu 24.04.5（`infra-lab-k8s-control`、Docker 29.1.3 / Containerlab 0.83.0 / Kind v0.27.0 / FRR 10.4.1 / Cilium 1.21.0-pre.4）で全検証を通過した。

- **トポロジー・冪等性**: `common/render-fabric.yml` で全 5 ノードの FRR 設定を生成（再実行は `changed=0 failed=0`）。`lab.sh up`（27行）で Kind クラスタ・Containerlab トポロジー・Cilium・BGP/probe マニフェストを一括展開できた。
- **疎通・障害復旧**: `sudo ./verify.sh --failover` が終了コード 0 で通過した。
  - `kube-proxy` DaemonSet 不在、両ノードの `lo` `/32`（`10.220.255.10/32`・`10.220.255.11/32`）、BGP 3 セッション（`k8s-tor1` / `k8s-tor2` / Cilium `127.0.0.2`）Established、IPv4 デフォルトの IPv6 リンクローカル 2-way ECMP を確認。
  - ノード間・Pod 間双方向・両 Pod → 外部クライアント（`10.220.240.14`）の疎通を確認。
  - 両 ToR での LoadBalancer VIP（`10.220.250.10/32`）2-way ECMP、正常時・`tor1` 片系断・復旧・`tor2` 片系断・復旧のすべてで、外部クライアントからの両ノード ping（全損失 0%）と `http://10.220.250.10/` の `probe` 応答を確認。
- **実機知見**:
  - BGP Unnumbered 環境で Cilium KPR を有効にするため、[cilium-values.yaml](cilium-values.yaml) に `devices: "k8s-tor+,lo"`・`nodePort.directRoutingDevice: "lo"`・`socketLB.enabled: false` を設定し、[topology.clab.yml](topology.clab.yml) でデータ NIC の `rp_filter=0` と `fib_multipath_hash_policy=1` を有効化している。

## 構成ファイル

- [cluster.yaml](cluster.yaml): Kind 2 ノードクラスタ定義（`disableDefaultCNI: true`, `kubeProxyMode: none`, 各ノード `node-ip`）
- [nodes.yml](nodes.yml) + `frr/*.conf.j2`: 全 5 ノード（`tor1`, `tor2`, `client`, `node0`, `node1`）の ASN・IP と FRR テンプレート
- [topology.clab.yml](topology.clab.yml): ToR・client・Kind ノード相乗り FRR（`node0`/`node1`）と全 6 リンクの定義
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
