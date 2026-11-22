#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -eq 0 || $(uname -s) != Linux ]]; then
  echo '専用 Linux VM の sudo が使える一般ユーザーで実行してください。' >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
config_template=$PWD/devstack.local.conf
stack_dir=$HOME/devstack-ovn-bgp
sudo -n apt-get install -y git frr jq
sudo -n modprobe vrf

if [[ ! -d $stack_dir/.git ]]; then
  git clone --depth 1 --branch stable/2026.2 https://opendev.org/openstack/devstack.git "$stack_dir"
fi

cd "$stack_dir"
if [[ ! -e local.conf ]]; then
  host_ip=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<NF; i++) if ($i=="src") {print $(i+1); exit}}')
  [[ -n $host_ip ]]
  umask 077
  temporary_config=$(mktemp ./local.conf.XXXXXX)
  trap 'rm -f "$temporary_config"' EXIT
  {
    IFS= read -r localrc
    printf '%s\n' "$localrc"
    printf 'HOST_IP=%s\nADMIN_PASSWORD=%s\n' "$host_ip" "$(openssl rand -hex 16)"
    cat
  } < "$config_template" > "$temporary_config"
  mv "$temporary_config" local.conf
fi

./stack.sh
