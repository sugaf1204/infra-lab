#!/usr/bin/env bash
set -euo pipefail

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"
repository=https://pkgs.k8s.io/core:/stable:/v1.34/deb

sudo apt-get update
sudo apt-get install -y ca-certificates curl gpg containerd conntrack
if ! modinfo vrf >/dev/null 2>&1; then
  sudo apt-get install -y "linux-modules-extra-$(uname -r)"
fi
curl -fsSLo Release.key "$repository/Release.key"
gpg --batch --dearmor --output kubernetes-apt-keyring.gpg Release.key
sudo install -d -m 0755 /etc/apt/keyrings
sudo install -m 0644 kubernetes-apt-keyring.gpg /etc/apt/keyrings/cilium-lab-kubernetes.gpg
printf 'deb [signed-by=/etc/apt/keyrings/cilium-lab-kubernetes.gpg] %s/ /\n' "$repository" |
  sudo tee /etc/apt/sources.list.d/cilium-lab-kubernetes.list >/dev/null
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

curl -fSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz
curl -fSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz.sha256sum
printf '%s  helm-v3.19.5-linux-amd64.tar.gz\n' \
  "$(awk '{print $1}' helm-v3.19.5-linux-amd64.tar.gz.sha256sum)" | sha256sum --check -
tar -xzf helm-v3.19.5-linux-amd64.tar.gz
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
