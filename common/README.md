# 共通セットアップ

Containerlab と Docker は node3 上の検証専用 VM で動かす。Docker によるブリッジとファイアウォールの変更はゲスト内に閉じる。

| libvirt VM | 用途 | OS | vCPU | RAM | ディスク |
| --- | --- | --- | --- | --- | --- |
| `infra-lab-switches` | 3ラボの Containerlab スイッチ | Ubuntu 24.04 amd64 | 2 | 1.5 GiB | 16 GiB |
| `infra-lab-k8s-control` | Kubernetes control plane | Ubuntu 24.04 amd64 | 6 | 5 GiB | 80 GiB |
| `infra-lab-k8s-worker` | Kubernetes worker | Ubuntu 24.04 amd64 | 2 | 3 GiB | 40 GiB |
| `infra-lab-openstack` | OpenStack コントローラー兼 compute | Ubuntu 26.04 amd64 | 8 | 12 GiB | 120 GiB |
| `infra-lab-openstack-compute` | OpenStack 追加 compute | Ubuntu 26.04 amd64 | 2 | 4 GiB | 60 GiB |

## 接続方法

管理端末から node3 を SSH 踏み台にする。全 VM の管理アドレスは静的に割り当てる。管理 NIC にデフォルトルートを設定しないため、node3 から同じ管理サブネット内で通信する。

| VM | 管理端末での SSH コマンド |
| --- | --- |
| fabric | `ssh -J node3 ubuntu@192.168.122.250` |
| Kubernetes control plane | `ssh -J node3 ubuntu@192.168.122.219` |
| Kubernetes worker | `ssh -J node3 ubuntu@192.168.122.7` |
| OpenStack controller | `ssh -J node3 ubuntu@192.168.122.119` |
| OpenStack 追加 compute | `ssh -J node3 ubuntu@192.168.122.99` |

![物理ホスト上の管理ネットワークと Kubernetes、OpenStack の5台の VM](network.svg)

[図のソース](network.dot)

## node3 の VM 管理

`vm.sh` は Ubuntu のベースイメージを独立した qcow2 にコピーし、各 VM の管理 NIC を専用ホストの libvirt `default` に接続し、cloud-init に固定アドレスを渡す。既存 VM から移行するときは各ラボ VM で `sudo ./common/management.sh static enp1s0` を実行し、固定 IP で SSH できることを確認する。ラボ専用の `default` ネットワークは node3 で `sudo ./common/management.sh disable-dhcp` を実行する。配布元のチェックサムを確認した各バージョンの Ubuntu Server クラウドイメージと管理ユーザーの SSH 公開鍵を指定する。

```bash
sudo ./common/vm.sh create fabric /path/to/noble-cloud.qcow2 /path/to/ssh.pub
sudo ./common/vm.sh create k8s-control /path/to/noble-cloud.qcow2 /path/to/ssh.pub
sudo ./common/vm.sh create k8s-worker /path/to/noble-cloud.qcow2 /path/to/ssh.pub
sudo ./common/vm.sh create openstack /path/to/resolute-cloud.qcow2 /path/to/ssh.pub
sudo ./common/vm.sh create openstack-compute /path/to/resolute-cloud.qcow2 /path/to/ssh.pub
```

旧プロファイルで構築した VM の場合は、ラボを停止してから `virsh shutdown` で VM を停止し、`sudo ./common/vm.sh resize fabric` または `sudo ./common/vm.sh resize openstack` を実行する。`sudo ./common/vm.sh start <役割>` で起動する。5台の最大メモリ割り当ては合計 25.5 GiB。作成・起動時は既存 VM の最大割り当てと稼働時の利用可能メモリを確認し、ホストに 5 GiB を確保できる範囲に制限する。各 VM の自動起動は無効。

## 検証用データ NIC

node3 で各役割の専用 NIC を取り付ける。

```bash
for role in fabric k8s-control k8s-fabric-control k8s-worker openstack openstack-compute openstack-fabric-controller openstack-fabric-compute; do
  sudo ./common/links.sh attach "$role"
done
```

各 VM 内で、該当する役割を指定して `sudo ./common/links.sh name <役割>` を実行する。fabric VM は `fabric`、`k8s-fabric-control`、`openstack-fabric-controller`、`openstack-fabric-compute` の4つを実行する。

| libvirt L2 セグメント | 接続先 VM | fabric の NIC 名 | 接続先の NIC 名 |
| --- | --- | --- | --- |
| `infra-lab-k8s-ctl-tor1`・`infra-lab-k8s-ctl-tor2` | Kubernetes control plane | `k8s-ctl-tor1`・`k8s-ctl-tor2` | `k8s-tor1`・`k8s-tor2` |
| `infra-lab-k8s-tor1`・`infra-lab-k8s-tor2` | Kubernetes worker | `k8s-tor1`・`k8s-tor2` | `k8s-tor1`・`k8s-tor2` |
| `infra-lab-ovn-ctl-tor1`・`infra-lab-ovn-ctl-tor2` | OpenStack controller | `ovn-ctl-tor1`・`ovn-ctl-tor2` | `ovn-tor1`・`ovn-tor2` |
| `infra-lab-ovn-tor1`・`infra-lab-ovn-tor2` | OpenStack compute | `ovn-tor1`・`ovn-tor2` | `ovn-tor1`・`ovn-tor2` |

各セグメントは独立したポイントツーポイント L2。OpenStack controller と compute は、それぞれ fabric VM 内の両 ToR に接続する。管理接続は上図の `default` ネットワークを使う。各ラボの起動スクリプトが fabric VM の専用 virtio NIC を ToR のネットワーク名前空間へ移し、撤去時に元の名前で返す。コンテナが異常終了して NIC 名が変わった場合は、対応する役割の `links.sh name` で MAC アドレスから名前を復元する。

## インストール

このリポジトリを検証専用 VM に取得し、ルートディレクトリで実行する。隔離した VM にはパッケージ・イメージを管理サブネットから供給する。依存の取得に外部アクセスが必要な場合は、構築時だけ管理端末の SSH リモート SOCKS とアプリケーションのプロキシ設定を使う。

```bash
sudo ./common/bootstrap.sh
sudo docker info --format '{{.ServerVersion}}'
sudo containerlab version
sudo docker image inspect quay.io/frrouting/frr:10.4.1 --format '{{.Id}}'
```

スクリプトは Ubuntu の `docker.io` と共通 CLI を導入し、Containerlab 0.83.0 を `/usr/local/bin/containerlab` に配置する。ラボ共通の FRR は 10.4.1 で、`frr/daemons` が zebra、bgpd、staticd を有効化する。Cilium と OpenStack 固有の依存関係は各ラボの手順で導入する。

- [Containerlab 0.83.0 の配布元](https://github.com/srl-labs/containerlab/releases/tag/v0.83.0)
- [FRR 10.4.1 の配布元](https://github.com/FRRouting/frr/releases/tag/frr-10.4.1)

## 撤収

各ラボの手順でリソースを停止する。VM だけ止める場合は node3 で `sudo virsh shutdown <VM名>` を実行する。完全撤去する場合は、対象 VM の停止とディスクパスを `virsh domstate` と `virsh domblklist` で確認し、必要なデータを退避してから定義と専用ディスクを削除する。

```bash
vm=infra-lab-switches # 対象のラボ VM 名を指定する
sudo virsh domblklist "$vm"
if [ "$(sudo env LC_ALL=C virsh domstate "$vm")" = "shut off" ]; then
  sudo virsh undefine "$vm" --nvram &&
    sudo rm -- "/var/lib/libvirt/images/$vm/root.qcow2" "/var/lib/libvirt/images/$vm/seed.iso" &&
    sudo rmdir -- "/var/lib/libvirt/images/$vm"
fi
```
