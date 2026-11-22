#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 || $(uname -s) != Linux ]]; then
  echo "Ubuntu 24.04 / 26.04 のラボ専用 VM で sudo を使って実行してください。" >&2
  exit 1
fi
. /etc/os-release
if [[ $ID != ubuntu || ( $VERSION_ID != 24.04 && $VERSION_ID != 26.04 ) || $(dpkg --print-architecture) != amd64 ]]; then
  echo "対象は Ubuntu 24.04 / 26.04 amd64 です。" >&2
  exit 1
fi

version=0.83.0
asset="containerlab_${version}_linux_amd64.tar.gz"
sha256=1ee43b8fd5979d8baa205e267480d69177f7461b2d1bf512df144800c08cfe2c
release_url="https://github.com/srl-labs/containerlab/releases/download/v${version}"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

apt-get update
apt-get install -y ca-certificates curl docker.io git iproute2 jq python3
systemctl enable --now docker
docker info --format '{{.ServerVersion}}'

curl --fail --silent --show-error --location --retry 3 --output "$work_dir/$asset" "$release_url/$asset"
printf '%s  %s\n' "$sha256" "$work_dir/$asset" | sha256sum --check
tar -xzf "$work_dir/$asset" -C "$work_dir" containerlab
"$work_dir/containerlab" version
install -m 0755 "$work_dir/containerlab" /usr/local/bin/containerlab
docker pull quay.io/frrouting/frr:10.4.1
