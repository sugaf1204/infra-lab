#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$EUID" != 0 ]]; then
  echo 'Run this lab as root on the dedicated Linux VM.' >&2
  exit 1
fi

action=${1:-}
failover=${2:-}
case "$action:$failover:$#" in
  fabric-up::1|fabric-down::1|verify-fabric::1|verify-fabric:--failover:2|prepare::1|up::1|join::1|join-config::1|verify::1|verify-node::1|down::1) ;;
  *) echo "Usage: $0 {fabric-up|fabric-down|verify-fabric [--failover]|prepare|up|join-config|join|verify|verify-node|down}" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077
state=.lab-state/kubeadm
mkdir -p "$state"
exec 9>"$state/lock"
flock 9

control_node=cilium-l3-node
control_ip=10.220.255.10
worker_node=cilium-l3-worker
worker_ip=10.220.255.11
uplinks=(k8s-tor1 k8s-tor2)
case "$(hostname -s)" in
  infra-lab-switches) role=fabric ;;
  infra-lab-k8s-control) role=control-plane; node=$control_node; node_ip=$control_ip ;;
  infra-lab-k8s-worker) role=worker; node=$worker_node; node_ip=$worker_ip ;;
  *) echo "Run on a dedicated Kubernetes lab VM." >&2; exit 2 ;;
esac

case "$role:$action" in
  fabric:fabric-*|fabric:verify-fabric|control-plane:prepare|control-plane:up|control-plane:join-config|control-plane:verify|control-plane:verify-node|control-plane:down|worker:prepare|worker:join|worker:verify-node|worker:down) ;;
  *) printf 'Action %s is unavailable on the %s VM.\n' "$action" "$role" >&2; exit 2 ;;
esac

tors=(clab-cilium-l3-tor1 clab-cilium-l3-tor2)
client=clab-cilium-l3-client
networkd_dropin=/etc/systemd/networkd.conf.d/90-infra-lab-cilium.conf
cri=unix:///run/containerd-cilium-lab/containerd.sock
vip=10.220.250.10
client_ip=10.220.240.14

export KUBECONFIG=/etc/kubernetes/admin.conf
export CLAB_RUNTIME=docker DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT

preserve_lab_routes() {
  if systemctl is-active --quiet systemd-networkd && ! cmp -s networkd-cilium-lab.conf "$networkd_dropin"; then
    install -D -m 0644 networkd-cilium-lab.conf "$networkd_dropin"
    systemctl restart systemd-networkd
  fi
}

fabric_nics() {
  local action=$1 index
  for index in "${!tors[@]}"; do
    ../common/tor-nic.sh "$action" "k8s-ctl-tor$((index + 1))" "${tors[index]}" eth1
    ../common/tor-nic.sh "$action" "${uplinks[index]}" "${tors[index]}" eth3
  done
}

fabric_up() {
    ansible-playbook -i localhost, -c local ../common/render-fabric.yml -e "lab_dir=$PWD"
  if ! docker container inspect -f '{{.State.Running}}' "${tors[0]}" "${tors[1]}" "$client" 2>/dev/null |
      awk '$0 == "true" { running++ } END { exit (running != 3) }'; then
    fabric_nics detach
    containerlab deploy --topo topology.clab.yml --reconfigure
  fi
  fabric_nics attach
}

fabric_down() {
  fabric_nics detach
  containerlab destroy --topo topology.clab.yml --cleanup
}

prepare_node() {
  if [[ ! -f $state/owned ]]; then
    if [[ -e /etc/kubernetes/admin.conf || -e /etc/kubernetes/kubelet.conf ||
          -e /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
      echo 'An existing Kubernetes cluster must be removed first.' >&2
      return 1
    fi
    touch "$state/owned"
  fi

  if [[ $(wc -l < /proc/swaps) -gt 1 ]]; then
    echo 'This lab requires a VM with swap disabled.' >&2
    return 1
  fi

  modprobe overlay
  preserve_lab_routes
  ansible-playbook -i localhost, -c local host.yml
  if ip -j -4 route show default | jq -e 'any(.[]; .protocol != "bgp")' >/dev/null; then
    echo 'Remove the management default before deploying the lab node.' >&2
    return 1
  fi
  install -D -m 0644 containerd.toml /etc/containerd/cilium-lab.toml
  install -m 0644 containerd-cilium-lab.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now containerd-cilium-lab.service kubelet.service
}

prepare() { prepare_node; }

up() {
  prepare_node
  if [[ ! -f $state/kubeadm-ready ]]; then
    if [[ -f $state/kubeadm-started ]]; then
      echo "Earlier kubeadm initialization was incomplete. Run '$0 down' before retrying." >&2
      return 1
    fi
    local version
    version=$(kubeadm version -o short)
    KUBERNETES_VERSION="$version" envsubst '${KUBERNETES_VERSION}' < kubeadm-init.yaml.in > "$state/init.yaml"
    touch "$state/kubeadm-started"
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u no_proxy -u NO_PROXY \
      kubeadm init --config "$state/init.yaml" --skip-token-print
    touch "$state/kubeadm-ready"
  fi

  kubectl label node "$node" node.kubernetes.io/exclude-from-external-load-balancers-
  helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
    --version 1.21.0-pre.4 --namespace kube-system --values cilium-values.yaml --wait --timeout 10m
  local crds=(
    crd/ciliumbgpadvertisements.cilium.io
    crd/ciliumbgpclusterconfigs.cilium.io
    crd/ciliumbgppeerconfigs.cilium.io
    crd/ciliumbgpnodeconfigoverrides.cilium.io
    crd/ciliumloadbalancerippools.cilium.io
  )
  kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
  local crd
  for crd in "${crds[@]}"; do
    kubectl wait --for=create --timeout=120s "$crd"
  done
  kubectl wait --for=condition=Established --timeout=120s "${crds[@]}"
  kubectl apply -f bgp.yaml -f probes.yaml
}

join_config() {
  local token cert_hash
  token=$(kubeadm token create --ttl 20m)
  cert_hash=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -pubkey -noout |
    openssl pkey -pubin -outform DER | openssl dgst -sha256 -r | awk '{print $1}')
  JOIN_TOKEN="$token" CA_HASH="$cert_hash" envsubst '${JOIN_TOKEN} ${CA_HASH}' < kubeadm-join.yaml.in
}

join() {
  prepare_node
  if [[ -f $state/kubeadm-ready ]]; then
    return
  fi
  if [[ -f $state/kubeadm-started ]]; then
    echo "Earlier kubeadm initialization was incomplete. Run '$0 down' before retrying." >&2
    return 1
  fi

  local attempt
  for ((attempt = 0; attempt < 45; attempt++)); do
    if check_default '["k8s-tor1","k8s-tor2"]' ip; then
      break
    fi
    sleep 2
  done
  check_default '["k8s-tor1","k8s-tor2"]' ip

  local join_file=$state/join.yaml
  trap 'rm -f "$state/join.yaml"' EXIT
  cat > "$join_file"
  touch "$state/kubeadm-started"
  kubeadm join --config "$join_file"
  touch "$state/kubeadm-ready"
  rm -f "$join_file"
  trap - EXIT
}

source ./verify.sh

down() {
  [[ -f $state/owned ]] || return 0
  if [[ -f $state/kubeadm-started ]]; then
    systemctl start containerd-cilium-lab.service
    kubeadm reset -f --cri-socket "$cri"
    rm -f /etc/cni/net.d/05-cilium.conflist
    rm -f "$state/kubeadm-started" "$state/kubeadm-ready"
  fi
  systemctl stop frr.service 2>/dev/null || true
  systemctl disable --now kubelet.service
  if [[ -f /etc/systemd/system/containerd-cilium-lab.service ]]; then
    systemctl disable --now containerd-cilium-lab.service
    rm -f /etc/systemd/system/containerd-cilium-lab.service /etc/containerd/cilium-lab.toml
    systemctl daemon-reload
  fi
  rm -f /etc/netplan/80-infra-lab-data.yaml /etc/sysctl.d/80-infra-lab-routing.conf
  netplan apply
  if cmp -s networkd-cilium-lab.conf "$networkd_dropin"; then
    rm -f "$networkd_dropin"
    if systemctl is-active --quiet systemd-networkd; then
      systemctl restart systemd-networkd
    fi
  fi
  rm -f "$state/owned" "$state/init.yaml" "$state/frr.conf"
}

"${action//-/_}"
