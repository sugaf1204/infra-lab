#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  exec sudo --preserve-env=http_proxy,https_proxy,no_proxy bash "$0" "$@"
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"
repository=https://pkgs.k8s.io/core:/stable:/v1.34/deb
frr_repository=https://deb.frrouting.org/frr

apt-get update
apt-get install -y ansible-core ca-certificates curl gettext-base gpg containerd conntrack jq
install -d -m 0755 /etc/apt/keyrings
curl -fsSLo Release.key "$repository/Release.key"
gpg --batch --dearmor --output /etc/apt/keyrings/cilium-lab-kubernetes.gpg Release.key
printf 'deb [signed-by=/etc/apt/keyrings/cilium-lab-kubernetes.gpg] %s/ /\n' "$repository" \
  > /etc/apt/sources.list.d/cilium-lab-kubernetes.list
curl -fsSLo /etc/apt/keyrings/frrouting.gpg "$frr_repository/keys.gpg"
printf 'deb [signed-by=/etc/apt/keyrings/frrouting.gpg] %s noble frr-10\n' "$frr_repository" \
  > /etc/apt/sources.list.d/frr.list
apt-get update
apt-get install -y frr kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

curl -fSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz
curl -fSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz.sha256sum
printf '%s  helm-v3.19.5-linux-amd64.tar.gz\n' \
  "$(awk '{print $1}' helm-v3.19.5-linux-amd64.tar.gz.sha256sum)" | sha256sum --check -
tar -xzf helm-v3.19.5-linux-amd64.tar.gz
install -m 0755 linux-amd64/helm /usr/local/bin/helm

modprobe overlay
printf 'overlay\n' > /etc/modules-load.d/cilium-lab.conf
install -D -m 0644 "$script_dir/networkd-cilium-lab.conf" /etc/systemd/networkd.conf.d/90-infra-lab-cilium.conf
systemctl restart systemd-networkd
install -D -m 0644 "$script_dir/containerd.toml" /etc/containerd/cilium-lab.toml
install -m 0644 "$script_dir/containerd-cilium-lab.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now containerd-cilium-lab.service kubelet.service
