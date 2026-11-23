#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -eq 0 || $(uname -s) != Linux ]]; then
  echo '専用 Linux VM の sudo が使える一般ユーザーで実行してください。' >&2
  exit 1
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
case "${1:-controller}:$#" in
  controller:0|controller:1)
    config_template=$PWD/devstack.local.conf
    expected_host=infra-lab-openstack
    ;;
  compute:2)
    config_template=$PWD/compute.local.conf
    expected_host=infra-lab-openstack-compute
    controller_ip=$2
    if [[ ! $controller_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo '管理ネットワーク上の controller IPv4 を指定してください。' >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: $0 [controller | compute CONTROLLER_IPV4]" >&2
    exit 2
    ;;
esac
if [[ $(hostname -s) != "$expected_host" ]]; then
  printf 'Run this command on the %s VM.\n' "$expected_host" >&2
  exit 1
fi

stack_dir=$HOME/devstack-ovn-bgp
if [[ -n ${controller_ip:-} && ! -e $stack_dir/local.conf ]]; then
  # The controller generates a 32-character lowercase hex value in this lab.
  if ! IFS= read -r shared_password || [[ ! $shared_password =~ ^[a-f0-9]{32}$ ]]; then
    echo '初回の compute セットアップには controller の ADMIN_PASSWORD を標準入力から渡してください。' >&2
    exit 1
  fi
fi

sudo -n apt-get update
sudo -n apt-get install -y git frr jq
sudo -n modprobe vrf

if [[ ! -d $stack_dir/.git ]]; then
  git clone --depth 1 --branch stable/2026.2 https://opendev.org/openstack/devstack.git "$stack_dir"
fi

cd "$stack_dir"
if [[ ! -e local.conf ]]; then
  management_nic=${MANAGEMENT_NIC:-enp1s0}
  host_ip=$(ip -j -4 address show dev "$management_nic" |
    jq -er '[.[].addr_info[] | select(.scope == "global") | .local] | select(length == 1) | .[0]')
  if [[ -z ${controller_ip:-} ]]; then
    shared_password=$(openssl rand -hex 16)
  fi
  umask 077
  temporary_config=$(mktemp ./local.conf.XXXXXX)
  trap 'rm -f "$temporary_config"' EXIT
  {
    IFS= read -r localrc
    printf '%s\n' "$localrc"
    printf 'HOST_IP=%s\nADMIN_PASSWORD=%s\n' "$host_ip" "$shared_password"
    if [[ -n ${controller_ip:-} ]]; then
      printf 'SERVICE_HOST=%s\n' "$controller_ip"
    fi
    cat
  } < "$config_template" > "$temporary_config"
  mv "$temporary_config" local.conf
  unset shared_password
fi

./stack.sh
