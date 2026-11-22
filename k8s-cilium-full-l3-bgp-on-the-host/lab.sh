#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$EUID" != 0 ]]; then
  echo 'Run this lab as root on the dedicated Linux VM.' >&2
  exit 1
fi

action=${1:-}
failover=${2:-}
case "$action:$failover:$#" in
  up::1|verify::1|verify:--failover:2|down::1) ;;
  *) echo "Usage: $0 {up|verify [--failover]|down}" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077
state=.lab-state/kubeadm
mkdir -p "$state"
exec 9>"$state/lock"
flock 9

node=cilium-l3-node
node_ip=10.220.255.10
node_frr=clab-cilium-l3-node-frr
host_frr=clab-cilium-l3-kube-host-frr
tors=(clab-cilium-l3-tor1 clab-cilium-l3-tor2)
client=clab-cilium-l3-client
uplink=cilium-uplink
return_link=cilium-routes
egress_vrf=cilium-egress
egress_table=220
cri=unix:///run/containerd-cilium-lab/containerd.sock
vip=10.220.250.10
pod_network=10.220.0.0/20
client_ip=10.220.240.14
client_network=$client_ip/32

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
  forward_rule "$1" -i "$return_link" -s "$client_network" -d "$pod_network" -j ACCEPT
  forward_rule "$1" -o "$return_link" -s "$pod_network" -d "$client_network" -j ACCEPT
}

setup_egress() {
  if ! ip link show "$egress_vrf" >/dev/null 2>&1; then
    ip link add "$egress_vrf" type vrf table "$egress_table"
  fi
  ip link set "$egress_vrf" up
}

configure_pod_routing() {
  ip link set "$return_link" master "$egress_vrf"
  ip link set "$return_link" up
  sysctl -w "net.ipv6.conf.$return_link.disable_ipv6=0"
  if [[ -z $(ip -4 rule show pref 990) ]]; then
    ip -4 rule add pref 990 iif "$egress_vrf" to "$pod_network" lookup main suppress_prefixlength 0
  fi
  if [[ -z $(ip -4 rule show pref 22010) ]]; then
    ip -4 rule add pref 22010 from "$pod_network" lookup main suppress_prefixlength 0
  fi
  if [[ -z $(ip -4 rule show pref 22011) ]]; then
    ip -4 rule add pref 22011 from "$pod_network" lookup "$egress_table"
  fi
  if [[ -z $(ip -4 rule show pref 22008) ]]; then
    ip -4 rule add pref 22008 from "$node_ip/32" lookup "$egress_table"
  fi
  if [[ -z $(ip -4 rule show pref 22009) ]]; then
    ip -4 rule add pref 22009 from "$node_ip/32" unreachable
  fi
  if [[ -z $(ip -4 rule show pref 22012) ]]; then
    ip -4 rule add pref 22012 from "$pod_network" unreachable
  fi
}

up() {
  if [[ ! -f $state/owned ]]; then
    if [[ -e /etc/kubernetes/admin.conf || -e /etc/kubernetes/manifests/kube-apiserver.yaml ]] ||
       docker container inspect "$node_frr" >/dev/null 2>&1 ||
       docker container inspect "$host_frr" >/dev/null 2>&1 ||
       docker container inspect "${tors[0]}" >/dev/null 2>&1 ||
       docker container inspect "${tors[1]}" >/dev/null 2>&1 ||
       docker container inspect "$client" >/dev/null 2>&1 ||
       ip link show "$uplink" >/dev/null 2>&1 ||
       ip link show "$egress_vrf" >/dev/null 2>&1; then
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
  modprobe vrf
  setup_egress
  ip address replace "$node_ip/32" dev lo
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
  sysctl -w "net.ipv6.conf.$uplink.disable_ipv6=0" \
    "net.ipv6.conf.$uplink.accept_ra=2" \
    "net.ipv6.conf.$uplink.accept_ra_defrtr=0"
  configure_pod_routing
  configure_forwarding add

  if [[ ! -f $state/kubeadm-ready ]]; then
    if [[ -f $state/kubeadm-started ]]; then
      echo "Earlier kubeadm initialization was incomplete. Run '$0 down' before retrying." >&2
      return 1
    fi
    cat > "$state/init.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $node_ip
nodeRegistration:
  name: $node
  criSocket: $cri
  kubeletExtraArgs:
    - name: node-ip
      value: $node_ip
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: $(kubeadm version -o short)
networking:
  podSubnet: $pod_network
  serviceSubnet: 10.221.0.0/16
EOF
    touch "$state/kubeadm-started"
    kubeadm init --config "$state/init.yaml"
    touch "$state/kubeadm-ready"
  fi

  if kubectl get node "$node" -o json |
    jq -e 'any(.spec.taints[]?; .key == "node-role.kubernetes.io/control-plane" and .effect == "NoSchedule")' >/dev/null; then
    kubectl taint node "$node" node-role.kubernetes.io/control-plane:NoSchedule-
  fi
  kubectl label node "$node" node.kubernetes.io/exclude-from-external-load-balancers-
  helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
    --version 1.21.0-pre.4 --namespace kube-system --values cilium-values.yaml --wait --timeout 10m
  local crds=(
    crd/ciliumbgpadvertisements.cilium.io
    crd/ciliumbgpclusterconfigs.cilium.io
    crd/ciliumbgppeerconfigs.cilium.io
    crd/ciliumloadbalancerippools.cilium.io
  )
  kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
  local crd
  for crd in "${crds[@]}"; do
    kubectl wait --for=create --timeout=120s "$crd"
  done
  kubectl wait --for=condition=Established --timeout=120s "${crds[@]}"
  kubectl apply -f bgp.yaml -f probes.yaml
  verify
}

check_peers() {
  docker exec "$1" vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e --argjson interfaces "$2" '
      .peers | keys == $interfaces and all(.[]; .state == "Established" and .idType == "interface")
    ' >/dev/null
}

check_routes() {
  local interfaces=$1
  shift
  "$@" | jq -e --argjson interfaces "$interfaces" '
    [.[] | select(.protocol == "bgp") | (.nexthops // [.])[] |
      select(.via.family == "inet6") | .dev] | sort == ($interfaces | sort)
  ' >/dev/null
}

check_tors() {
  local pod_ip=$1 tor prefix
  shift
  for tor in "$@"; do
    for prefix in "$pod_ip/32" "$node_ip/32" "$vip/32"; do
      check_routes '["eth1"]' docker exec "$tor" ip -j -4 route show exact "$prefix" || return 1
    done
  done
}

wait_for_fabric() {
  local pod_ip=$1 client_interfaces=$2 node_interfaces=$3
  shift 3
  local deadline=$((SECONDS + 90))
  until check_routes "$client_interfaces" docker exec "$client" ip -j -4 route show default &&
        check_routes "$node_interfaces" docker exec "$node_frr" ip -j -4 route show exact "$client_network" &&
        check_tors "$pod_ip" "$@"; do
    if (( SECONDS >= deadline )); then
      docker exec "$node_frr" vtysh -c 'show bgp ipv4 unicast summary'
      return 1
    fi
    sleep 2
  done
}

check_traffic() {
  local pod_ip=$1 pod_dev=$2
  ip -j -4 route get "$client_ip" from "$pod_ip" iif "$pod_dev" |
    jq -e --arg dev "$return_link" 'any(.[]; .dev == $dev and .via.family == "inet6")' >/dev/null
  docker exec "$client" ping -c 2 -W 2 "$node_ip"
  docker exec "$client" ping -c 2 -W 2 "$pod_ip"
  docker exec "$client" wget -q -T 5 -O - "http://$vip/" | grep -Fx probe
}

set_tor_links() {
  docker exec "$1" ip link set eth1 "$2"
  docker exec "$1" ip link set eth2 "$2"
}

verify() {
  local pod_ip pod_dev tor
  kubectl wait --for=condition=Ready --timeout=180s "node/$node"
  kubectl -n lab-probe wait --for=condition=Ready --timeout=180s pod/probe
  kubectl -n lab-probe wait --timeout=120s \
    --for="jsonpath={.status.loadBalancer.ingress[0].ip}=$vip" service/probe
  kubectl get node "$node" -o json | jq -e --arg ip "$node_ip" \
    'any(.status.addresses[]; .type == "InternalIP" and .address == $ip)' >/dev/null
  ip -j -4 address show dev lo | jq -e --arg ip "$node_ip" \
    'any(.[].addr_info[]; .local == $ip and .prefixlen == 32)' >/dev/null
  pod_ip=$(kubectl -n lab-probe get pod probe -o 'jsonpath={.status.podIP}')
  pod_dev=$(ip -j -4 route show exact "$pod_ip/32" |
    jq -er '.[] | select(.protocol == "kernel") | .dev')
  wait_for_fabric "$pod_ip" '["eth1","eth2"]' '["eth2","eth4"]' "${tors[@]}"
  check_peers "$node_frr" '["eth1","eth2","eth3","eth4"]'
  check_peers "$client" '["eth1","eth2"]'
  for tor in "${tors[@]}"; do
    check_peers "$tor" '["eth1","eth2"]'
  done
  check_routes '["cilium-routes"]' ip -j -4 route show table "$egress_table" default
  check_routes '["eth3"]' docker exec "$node_frr" ip -j -4 route show exact "$pod_ip/32"
  check_traffic "$pod_ip" "$pod_dev"

  if [[ $failover == --failover ]]; then
    trap 'for restore_tor in "${tors[@]}"; do set_tor_links "$restore_tor" up || true; done' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for tor in "${tors[@]}"; do
      set_tor_links "$tor" down
      if [[ $tor == "${tors[0]}" ]]; then
        wait_for_fabric "$pod_ip" '["eth2"]' '["eth4"]' "${tors[1]}"
      else
        wait_for_fabric "$pod_ip" '["eth1"]' '["eth2"]' "${tors[0]}"
      fi
      check_traffic "$pod_ip" "$pod_dev"
      set_tor_links "$tor" up
      wait_for_fabric "$pod_ip" '["eth1","eth2"]' '["eth2","eth4"]' "${tors[@]}"
    done
    trap - EXIT INT TERM
    check_traffic "$pod_ip" "$pod_dev"
  fi
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
  ip -4 rule del pref 990 iif "$egress_vrf" to "$pod_network" lookup main suppress_prefixlength 0 2>/dev/null || true
  ip -4 rule del pref 22009 from "$node_ip/32" unreachable 2>/dev/null || true
  ip -4 rule del pref 22008 from "$node_ip/32" lookup "$egress_table" 2>/dev/null || true
  ip -4 rule del pref 22012 from "$pod_network" unreachable 2>/dev/null || true
  ip -4 rule del pref 22011 from "$pod_network" lookup "$egress_table" 2>/dev/null || true
  ip -4 rule del pref 22010 from "$pod_network" lookup main suppress_prefixlength 0 2>/dev/null || true
  if [[ -f $state/topology-started ]]; then
    containerlab destroy --topo topology.clab.yml --cleanup
    rm -f "$state/topology-started" "$state/topology-ready"
  fi
  if ip link show "$egress_vrf" >/dev/null 2>&1; then
    ip link del "$egress_vrf"
  fi
  systemctl disable --now kubelet.service
  if [[ -f /etc/systemd/system/containerd-cilium-lab.service ]]; then
    systemctl disable --now containerd-cilium-lab.service
    rm -f /etc/systemd/system/containerd-cilium-lab.service /etc/containerd/cilium-lab.toml
    systemctl daemon-reload
  fi
  ip address del "$node_ip/32" dev lo 2>/dev/null || true
  rm -f "$state/owned" "$state/init.yaml"
}

"$action"
