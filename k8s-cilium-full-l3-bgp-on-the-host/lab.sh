#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$EUID" != 0 ]]; then
  echo 'Run this lab as root on the dedicated Linux VM.' >&2
  exit 1
fi

action=${1:-}
case "$action" in
  up|verify|down) ;;
  *) echo "Usage: $0 {up|verify|down}" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077
state=.lab-state/kubeadm
mkdir -p "$state"
exec 9>"$state/lock"
flock 9

node=cilium-l3-node
tor=clab-cilium-l3-tor1
client=clab-cilium-l3-client
uplink=cilium-uplink
cri=unix:///run/containerd-cilium-lab/containerd.sock
vip=10.220.250.10
pod_network=10.220.0.0/20
client_network=10.220.240.12/30

export KUBECONFIG=/etc/kubernetes/admin.conf
export CLAB_RUNTIME=docker DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT

forward_rule() {
  local operation=$1
  shift
  if [[ $operation == add ]]; then
    iptables -C DOCKER-USER "$@" 2>/dev/null || iptables -I DOCKER-USER 1 "$@"
  elif iptables -C DOCKER-USER "$@" 2>/dev/null; then
    iptables -D DOCKER-USER "$@"
  fi
}

configure_forwarding() {
  forward_rule "$1" -i "$uplink" -s "$client_network" -d "$pod_network" -j ACCEPT
  forward_rule "$1" -o "$uplink" -s "$pod_network" -d "$client_network" -j ACCEPT
}

up() {
  if [[ ! -f $state/owned ]]; then
    if [[ -e /etc/kubernetes/admin.conf || -e /etc/kubernetes/manifests/kube-apiserver.yaml ]] ||
       docker container inspect "$tor" >/dev/null 2>&1 ||
       docker container inspect "$client" >/dev/null 2>&1 ||
       ip link show "$uplink" >/dev/null 2>&1; then
      echo 'An existing Kubernetes cluster or lab topology must be removed first.' >&2
      return 1
    fi
    touch "$state/owned"
  fi

  if [[ $(wc -l < /proc/swaps) -gt 1 ]]; then
    echo 'This lab requires a VM with swap disabled.' >&2
    return 1
  fi

  modprobe overlay
  modprobe br_netfilter
  sysctl -w net.ipv4.ip_forward=1
  install -D -m 0644 containerd.toml /etc/containerd/cilium-lab.toml
  install -m 0644 containerd-cilium-lab.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now containerd-cilium-lab.service kubelet.service

  if [[ ! -f $state/topology-ready ]]; then
    if [[ -f $state/topology-started ]]; then
      echo "Earlier topology deployment was incomplete. Run '$0 down' before retrying." >&2
      return 1
    fi
    touch "$state/topology-started"
    containerlab deploy --topo topology.clab.yml
    touch "$state/topology-ready"
  fi
  ip link set "$uplink" up
  ip -4 addr replace 10.220.240.2/30 dev "$uplink"
  ip -4 route replace "$client_network" via 10.220.240.1 dev "$uplink"
  configure_forwarding add

  if [[ ! -f $state/kubeadm-ready ]]; then
    if [[ -f $state/kubeadm-started ]]; then
      echo "Earlier kubeadm initialization was incomplete. Run '$0 down' before retrying." >&2
      return 1
    fi
    local management_ip
    management_ip=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -n $management_ip ]]
    touch "$state/kubeadm-started"
    kubeadm init --node-name "$node" --cri-socket "$cri" \
      --apiserver-advertise-address "$management_ip" \
      --kubernetes-version "$(kubeadm version -o short)" \
      --pod-network-cidr "$pod_network" --service-cidr 10.221.0.0/16
    touch "$state/kubeadm-ready"
  fi

  if kubectl get node "$node" -o json |
    jq -e 'any(.spec.taints[]?; .key == "node-role.kubernetes.io/control-plane" and .effect == "NoSchedule")' >/dev/null; then
    kubectl taint node "$node" node-role.kubernetes.io/control-plane:NoSchedule-
  fi
  helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
    --version 1.18.17 --namespace kube-system --values cilium-values.yaml --wait --timeout 10m
  local crds=(
    crd/ciliumbgpadvertisements.cilium.io
    crd/ciliumbgpclusterconfigs.cilium.io
    crd/ciliumbgppeerconfigs.cilium.io
    crd/ciliumloadbalancerippools.cilium.io
  )
  kubectl wait --for=create --timeout=120s "${crds[@]}"
  kubectl wait --for=condition=Established --timeout=120s "${crds[@]}"
  kubectl apply -f bgp.yaml -f probes.yaml
  verify
}

verify() {
  local pod_ip pod_cidr deadline
  kubectl wait --for=condition=Ready --timeout=180s "node/$node"
  kubectl -n lab-probe wait --for=condition=Ready --timeout=180s pod/probe
  kubectl -n lab-probe wait --timeout=120s \
    --for="jsonpath={.status.loadBalancer.ingress[0].ip}=$vip" service/probe
  pod_ip=$(kubectl -n lab-probe get pod probe -o 'jsonpath={.status.podIP}')
  pod_cidr=$(kubectl get node "$node" -o 'jsonpath={.spec.podCIDR}')

  deadline=$((SECONDS + 90))
  until docker exec "$tor" ip -4 route show exact "$pod_cidr" | grep -F 'via 10.220.240.2 dev eth1' >/dev/null &&
        docker exec "$tor" ip -4 route show exact "$vip/32" | grep -F 'via 10.220.240.2 dev eth1' >/dev/null; do
    if (( SECONDS >= deadline )); then
      docker exec "$tor" vtysh -c 'show bgp ipv4 unicast summary'
      return 1
    fi
    sleep 2
  done

  ip -4 route get 10.220.240.14 | grep -F "via 10.220.240.1 dev $uplink"
  docker exec "$client" ping -c 2 -W 2 "$pod_ip"
  docker exec "$client" wget -q -T 5 -O - "http://$vip/" | grep -Fx probe
}

down() {
  [[ -f $state/owned ]] || return 0
  if [[ -f $state/kubeadm-started ]]; then
    systemctl start containerd-cilium-lab.service
    kubeadm reset -f --cri-socket "$cri"
    rm -f /etc/cni/net.d/05-cilium.conflist
    rm -f "$state/kubeadm-started" "$state/kubeadm-ready"
  fi
  configure_forwarding remove
  if [[ -f $state/topology-started ]]; then
    containerlab destroy --topo topology.clab.yml --cleanup
    rm -f "$state/topology-started" "$state/topology-ready"
  fi
  systemctl disable --now kubelet.service
  if [[ -f /etc/systemd/system/containerd-cilium-lab.service ]]; then
    systemctl disable --now containerd-cilium-lab.service
    rm -f /etc/systemd/system/containerd-cilium-lab.service /etc/containerd/cilium-lab.toml
    systemctl daemon-reload
  fi
  rm -f "$state/owned"
}

"$action"
