#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$EUID" != 0 ]]; then
  echo 'Run this lab as root on the dedicated Linux VM.' >&2
  exit 1
fi

action=${1:-}
failover=${2:-}
case "$action:$failover:$#" in
  up::1|join::1|join-config::1|verify::1|verify:--failover:2|verify-node::1|down::1) ;;
  *) echo "Usage: $0 {up|join-config|join|verify [--failover]|verify-node|down}" >&2; exit 2 ;;
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
node_network=10.220.255.10/31

role=control-plane
node=$control_node
node_ip=$control_ip
topology=topology.clab.yml
uplinks=(cilium-tor1 cilium-tor2)
if [[ $(hostname -s) == infra-lab-k8s-worker ]]; then
  role=worker
  node=$worker_node
  node_ip=$worker_ip
  topology=worker.clab.yml
  uplinks=(k8s-tor1 k8s-tor2)
fi

case "$role:$action" in
  worker:up|worker:join-config|worker:verify|control-plane:join)
    printf 'Action %s is unavailable on the %s VM.\n' "$action" "$role" >&2
    exit 2
    ;;
esac

worker_links=(k8s-tor1 k8s-tor2)

host_frr=clab-cilium-l3-host-frr
tors=(clab-cilium-l3-tor1 clab-cilium-l3-tor2)
client=clab-cilium-l3-client
egress_vrf=cilium-egress
egress_table=220
networkd_dropin=/etc/systemd/networkd.conf.d/90-infra-lab-cilium.conf
cri=unix:///run/containerd-cilium-lab/containerd.sock
vip=10.220.250.10
pod_network=10.220.0.0/20
client_ip=10.220.240.14

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
  local uplink
  for uplink in "${uplinks[@]}"; do
    forward_rule "$1" -i "$uplink" -d "$pod_network" -j ACCEPT
    forward_rule "$1" -o "$uplink" -s "$pod_network" -j ACCEPT
  done
}

setup_egress() {
  if ! ip link show "$egress_vrf" >/dev/null 2>&1; then
    ip link add "$egress_vrf" type vrf table "$egress_table"
  fi
  ip link set "$egress_vrf" up
}

configure_pod_routing() {
  local uplink
  for uplink in "${uplinks[@]}"; do
    ip link set "$uplink" master "$egress_vrf"
    ip link set "$uplink" up
    sysctl -w "net.ipv6.conf.$uplink.disable_ipv6=0" \
      "net.ipv6.conf.$uplink.accept_ra=2" "net.ipv6.conf.$uplink.accept_ra_defrtr=0"
  done
  if [[ -z $(ip -4 rule show pref 990) ]]; then
    ip -4 rule add pref 990 to "$pod_network" lookup main suppress_prefixlength 0
  fi
  if [[ -z $(ip -4 rule show pref 991) ]]; then
    ip -4 rule add pref 991 to "$pod_network" lookup "$egress_table" suppress_prefixlength 0
  fi
  if [[ -z $(ip -4 rule show pref 992) ]]; then
    ip -4 rule add pref 992 to "$node_network" lookup "$egress_table" suppress_prefixlength 0
  fi
  if [[ -z $(ip -4 rule show pref 22010) ]]; then
    ip -4 rule add pref 22010 from "$pod_network" lookup main suppress_prefixlength 0
  fi
  if [[ -z $(ip -4 rule show pref 22011) ]]; then
    ip -4 rule add pref 22011 from "$pod_network" lookup "$egress_table"
  fi
  if [[ -z $(ip -4 rule show pref 22007) ]]; then
    ip -4 rule add pref 22007 from "$node_ip/32" lookup main suppress_prefixlength 0
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

preserve_lab_routes() {
  if systemctl is-active --quiet systemd-networkd && ! cmp -s networkd-cilium-lab.conf "$networkd_dropin"; then
    install -D -m 0644 networkd-cilium-lab.conf "$networkd_dropin"
    systemctl restart systemd-networkd
  fi
}

prepare_node() {
  local link
  if [[ ! -f $state/owned ]]; then
    if [[ -e /etc/kubernetes/admin.conf || -e /etc/kubernetes/kubelet.conf ||
          -e /etc/kubernetes/manifests/kube-apiserver.yaml ]] ||
       docker container inspect "$host_frr" >/dev/null 2>&1 ||
       docker container inspect "${tors[0]}" >/dev/null 2>&1 ||
       docker container inspect "${tors[1]}" >/dev/null 2>&1 ||
       docker container inspect "$client" >/dev/null 2>&1 ||
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

  for link in "${worker_links[@]}"; do ip link show "$link" >/dev/null; done

  modprobe overlay
  modprobe br_netfilter
  modprobe vrf
  preserve_lab_routes
  setup_egress
  ip address replace "$node_ip/32" dev lo
  sysctl -w net.ipv4.ip_forward=1
  if [[ ! -f $state/tcp-l3mdev-accept ]]; then
    sysctl -n net.ipv4.tcp_l3mdev_accept > "$state/tcp-l3mdev-accept"
  fi
  sysctl -w net.ipv4.tcp_l3mdev_accept=1
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
    containerlab deploy --topo "$topology"
    touch "$state/topology-ready"
  fi
  configure_pod_routing
  configure_forwarding add
}

up() {
  prepare_node
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
    kubeadm init --config "$state/init.yaml" --skip-token-print
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
  cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $control_ip:6443
    token: $token
    caCertHashes:
      - sha256:$cert_hash
nodeRegistration:
  name: $worker_node
  criSocket: $cri
  kubeletExtraArgs:
    - name: node-ip
      value: $worker_ip
EOF
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
    if check_routes '["k8s-tor1","k8s-tor2"]' ip -j -4 route show table "$egress_table" exact "$control_ip/32"; then
      break
    fi
    sleep 2
  done
  check_routes '["k8s-tor1","k8s-tor2"]' ip -j -4 route show table "$egress_table" exact "$control_ip/32"

  local join_file=$state/join.yaml
  trap 'rm -f "$state/join.yaml"' EXIT
  cat > "$join_file"
  touch "$state/kubeadm-started"
  kubeadm join --config "$join_file"
  touch "$state/kubeadm-ready"
  rm -f "$join_file"
  trap - EXIT
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
      select((.via.host // .gateway // "") | startswith("fe80:")) | .dev] | sort == ($interfaces | sort)
  ' >/dev/null
}

no_ipv4_default() {
  "$@" | jq -e 'length == 0' >/dev/null
}

check_tors() {
  local control_pod_ip=$1 worker_pod_ip=$2 tor prefix
  shift 2
  for tor in "$@"; do
    for prefix in "$control_pod_ip/32" "$control_ip/32"; do
      check_routes '["eth1"]' docker exec "$tor" ip -j -4 route show exact "$prefix" || return 1
    done
    for prefix in "$worker_pod_ip/32" "$worker_ip/32"; do
      check_routes '["eth3"]' docker exec "$tor" ip -j -4 route show exact "$prefix" || return 1
    done
    check_routes '["eth1","eth3"]' docker exec "$tor" ip -j -4 route show exact "$vip/32" || return 1
  done
}

wait_for_fabric() {
  local control_pod_ip=$1 worker_pod_ip=$2 client_interfaces=$3 node_interfaces=$4 worker_cilium=$5
  shift 5
  local worker_interfaces=${node_interfaces//cilium-tor/k8s-tor}
  local worker_routes=(kubectl --request-timeout=5s -n kube-system exec "$worker_cilium" -- ip -j)
  local deadline=$((SECONDS + 90))
  until check_routes "$client_interfaces" docker exec "$client" ip -j -6 route show default &&
        no_ipv4_default docker exec "$client" ip -j -4 route show default &&
        check_routes "$node_interfaces" ip -j -6 route show table "$egress_table" default &&
        no_ipv4_default ip -j -4 route show table "$egress_table" default &&
        check_routes "$worker_interfaces" "${worker_routes[@]}" -6 route show table "$egress_table" default &&
        no_ipv4_default "${worker_routes[@]}" -4 route show table "$egress_table" default &&
        check_routes "$worker_interfaces" "${worker_routes[@]}" -4 route show table "$egress_table" exact "$control_pod_ip/32" &&
        check_routes "$client_interfaces" docker exec "$client" ip -j -4 route show exact "$worker_pod_ip/32" &&
        check_routes "$client_interfaces" docker exec "$client" ip -j -4 route show exact "$control_pod_ip/32" &&
        check_routes "$client_interfaces" docker exec "$client" ip -j -4 route show exact "$vip/32" &&
        check_routes "$node_interfaces" ip -j -4 route show table "$egress_table" exact "$worker_pod_ip/32" &&
        check_tors "$control_pod_ip" "$worker_pod_ip" "$@"; do
    if (( SECONDS >= deadline )); then
      docker exec "$host_frr" vtysh -c 'show bgp ipv4 unicast summary' -c "show bgp vrf $egress_vrf ipv4 unicast summary"
      return 1
    fi
    sleep 2
  done
}

check_traffic() {
  local control_pod=$1 control_pod_ip=$2 worker_pod=$3 worker_pod_ip=$4 address
  for address in "$control_ip" "$worker_ip" "$control_pod_ip" "$worker_pod_ip"; do
    docker exec "$client" ping -c 2 -W 2 "$address"
  done
  kubectl -n lab-probe exec "$control_pod" -- ping -c 2 -W 2 "$worker_pod_ip"
  kubectl -n lab-probe exec "$worker_pod" -- ping -c 2 -W 2 "$control_pod_ip"
  docker exec "$client" wget -q -T 5 -O - "http://$vip/" | grep -Fx probe
}

set_tor_links() {
  local interface
  for interface in eth1 eth2 eth3; do
    docker exec "$1" ip link set "$interface" "$2"
  done
}

verify_node() {
  local interfaces other_ip
  interfaces=$(printf '%s\n' "${uplinks[@]}" | jq -R . | jq -sc .)
  other_ip=$worker_ip
  if [[ $role == worker ]]; then
    other_ip=$control_ip
  fi

  ip -j -4 address show dev lo | jq -e --arg ip "$node_ip" \
    '[.[].addr_info[] | select(.scope == "global")] | length == 1 and .[0].local == $ip and .[0].prefixlen == 32' >/dev/null
  docker exec "$host_frr" vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e --arg peer 127.0.0.2 '.peers[$peer].state == "Established" and .peers[$peer].remoteAs == 65201' >/dev/null
  docker exec "$host_frr" vtysh -c "show bgp vrf $egress_vrf ipv4 unicast summary json" |
    jq -e --argjson ports "$interfaces" '.peers | keys == $ports and all(.[]; .state == "Established" and .idType == "interface")' >/dev/null
  check_routes "$interfaces" ip -j -6 route show table "$egress_table" default
  no_ipv4_default ip -j -4 route show table "$egress_table" default
  check_routes "$interfaces" ip -j -4 route show table "$egress_table" exact "$client_ip/32"
  check_routes "$interfaces" ip -j -4 route show table "$egress_table" exact "$other_ip/32"
  ping -c 2 -W 2 "$other_ip"
}

probe_info() {
  kubectl -n lab-probe get pods -l app=probe --field-selector "spec.nodeName=$1" -o json |
    jq -er '.items | select(length == 1) | .[0] | [.metadata.name, .status.podIP] | @tsv'
}

verify() {
  local control_pod control_pod_ip worker_pod worker_pod_ip worker_cilium tor result
  kubectl wait --for=condition=Ready --timeout=180s "node/$control_node" "node/$worker_node"
  kubectl -n lab-probe rollout status daemonset/probe --timeout=180s
  kubectl -n lab-probe wait --timeout=120s \
    --for="jsonpath={.status.loadBalancer.ingress[0].ip}=$vip" service/probe
  kubectl get node "$control_node" "$worker_node" -o json |
    jq -e --arg control "$control_ip" --arg worker "$worker_ip" '
      [.items[].status.addresses[] | select(.type == "InternalIP").address] | sort == [$control,$worker]
    ' >/dev/null
  result=$(probe_info "$control_node")
  IFS=$'	' read -r control_pod control_pod_ip <<< "$result"
  result=$(probe_info "$worker_node")
  IFS=$'	' read -r worker_pod worker_pod_ip <<< "$result"
  worker_cilium=$(kubectl -n kube-system get pods -l k8s-app=cilium \
    --field-selector "spec.nodeName=$worker_node,status.phase=Running" \
    -o json | jq -er '.items | select(length == 1) | .[0].metadata.name')

  wait_for_fabric "$control_pod_ip" "$worker_pod_ip" '["eth1","eth2"]' '["cilium-tor1","cilium-tor2"]' "$worker_cilium" "${tors[@]}"
  verify_node
  check_peers "$client" '["eth1","eth2"]'
  for tor in "${tors[@]}"; do
    check_peers "$tor" '["eth1","eth2","eth3"]'
  done
  check_traffic "$control_pod" "$control_pod_ip" "$worker_pod" "$worker_pod_ip"

  if [[ $failover == --failover ]]; then
    trap 'for restore_tor in "${tors[@]}"; do set_tor_links "$restore_tor" up || true; done' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for tor in "${tors[@]}"; do
      printf 'Testing failover with %s down\n' "$tor"
      set_tor_links "$tor" down
      if [[ $tor == "${tors[0]}" ]]; then
        wait_for_fabric "$control_pod_ip" "$worker_pod_ip" '["eth2"]' '["cilium-tor2"]' "$worker_cilium" "${tors[1]}"
      else
        wait_for_fabric "$control_pod_ip" "$worker_pod_ip" '["eth1"]' '["cilium-tor1"]' "$worker_cilium" "${tors[0]}"
      fi
      check_traffic "$control_pod" "$control_pod_ip" "$worker_pod" "$worker_pod_ip"
      set_tor_links "$tor" up
      wait_for_fabric "$control_pod_ip" "$worker_pod_ip" '["eth1","eth2"]' '["cilium-tor1","cilium-tor2"]' "$worker_cilium" "${tors[@]}"
    done
    trap - EXIT INT TERM
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
  if [[ -f $state/tcp-l3mdev-accept ]]; then
    sysctl -w "net.ipv4.tcp_l3mdev_accept=$(cat "$state/tcp-l3mdev-accept")"
    rm -f "$state/tcp-l3mdev-accept"
  fi
  ip -4 rule del pref 992 to "$node_network" lookup "$egress_table" suppress_prefixlength 0 2>/dev/null || true
  ip -4 rule del pref 991 to "$pod_network" lookup "$egress_table" suppress_prefixlength 0 2>/dev/null || true
  ip -4 rule del pref 990 to "$pod_network" lookup main suppress_prefixlength 0 2>/dev/null || true
  ip -4 rule del pref 22009 from "$node_ip/32" unreachable 2>/dev/null || true
  ip -4 rule del pref 22008 from "$node_ip/32" lookup "$egress_table" 2>/dev/null || true
  ip -4 rule del pref 22007 from "$node_ip/32" lookup main suppress_prefixlength 0 2>/dev/null || true
  ip -4 rule del pref 22012 from "$pod_network" unreachable 2>/dev/null || true
  ip -4 rule del pref 22011 from "$pod_network" lookup "$egress_table" 2>/dev/null || true
  ip -4 rule del pref 22010 from "$pod_network" lookup main suppress_prefixlength 0 2>/dev/null || true
  if [[ -f $state/topology-started ]]; then
    containerlab destroy --topo "$topology" --cleanup
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
  if cmp -s networkd-cilium-lab.conf "$networkd_dropin"; then
    rm -f "$networkd_dropin"
    if systemctl is-active --quiet systemd-networkd; then
      systemctl restart systemd-networkd
    fi
  fi
  rm -f "$state/owned" "$state/init.yaml"
}

"${action//-/_}"
