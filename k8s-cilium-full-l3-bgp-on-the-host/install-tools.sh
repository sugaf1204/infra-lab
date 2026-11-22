#!/usr/bin/env bash
set -euo pipefail

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -fSLO https://github.com/kubernetes-sigs/kind/releases/download/v0.30.0/kind-linux-amd64
curl -fSLO https://github.com/kubernetes-sigs/kind/releases/download/v0.30.0/kind-linux-amd64.sha256sum
sha256sum --check kind-linux-amd64.sha256sum

curl -fSLO https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl
curl -fSLO https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl.sha256
printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check -

curl -fSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz
curl -fSLO https://get.helm.sh/helm-v3.19.5-linux-amd64.tar.gz.sha256sum
printf '%s  helm-v3.19.5-linux-amd64.tar.gz\n' \
  "$(awk '{print $1}' helm-v3.19.5-linux-amd64.tar.gz.sha256sum)" | sha256sum --check -
tar -xzf helm-v3.19.5-linux-amd64.tar.gz
sudo install -m 0755 kind-linux-amd64 /usr/local/bin/kind
sudo install -m 0755 kubectl linux-amd64/helm /usr/local/bin/
