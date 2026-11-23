#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  exec sudo --preserve-env=http_proxy,https_proxy,no_proxy bash "$0" "$@"
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

# kind
curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
install -m 0755 kind /usr/local/bin/kind

# kubectl
k8s_ver=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo kubectl "https://dl.k8s.io/release/${k8s_ver}/bin/linux/amd64/kubectl"
install -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl -fsSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz
curl -fsSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz.sha256sum
printf '%s  helm-v3.19.5-linux-amd64.tar.gz\n' \
  "$(awk '{print $1}' helm-v3.19.5-linux-amd64.tar.gz.sha256sum)" | sha256sum --check -
tar -xzf helm-v3.19.5-linux-amd64.tar.gz
install -m 0755 linux-amd64/helm /usr/local/bin/helm
