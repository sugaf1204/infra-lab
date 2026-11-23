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
  infra-lab-k8s-control) role=control-plane; node=$control_node; node_ip=$control_ip; asn=65202 ;;
  infra-lab-k8s-worker) role=worker; node=$worker_node; node_ip=$worker_ip; asn=65204 ;;
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
pod_network=10.220.0.0/20
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

configure_host_frr() {
  sed -i -e 's/^bgpd=no$/bgpd=yes/' -e 's/^staticd=yes$/staticd=no/' /etc/frr/daemons
  sed -e "s/@NODE_IP@/$node_ip/g" -e "s/@ASN@/$asn/g" frr/node.conf.in > "$state/frr.conf"
  install -o frr -g frr -m 0640 "$state/frr.conf" /etc/frr/frr.conf
  systemctl enable --now frr.service
  systemctl restart frr.service
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
  ip address replace "$node_ip/32" dev lo
  sysctl -qw net.ipv4.ip_forward=1 net.ipv4.fib_multipath_hash_policy=1
  local uplink
  for uplink in "${uplinks[@]}"; do ip link set "$uplink" up; done
  if ip -j -4 route show default | jq -e 'any(.[]; .protocol != "bgp")' >/dev/null; then
    echo 'Remove the management default before deploying the lab node.' >&2
    return 1
  fi
  install -D -m 0644 containerd.toml /etc/containerd/cilium-lab.toml
  install -m 0644 containerd-cilium-lab.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now containerd-cilium-lab.service kubelet.service
  configure_host_frr
}

prepare() { prepare_node; }

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
    kubeadm init --config "$state/init.yaml" --skip-phases=addon/kube-proxy --skip-token-print
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

check_default() {
  local links=$1
  shift
  check_routes "$links" "$@" -j -4 route show default &&
    "$@" -j -4 route show default | jq -e 'length == 1 and .[0].protocol == "bgp"' >/dev/null &&
    "$@" -j -4 route get fibmatch "$client_ip" | jq -e '.[0].dst == "default"' >/dev/null
}

set_tor_links() {
  local interface
  for interface in eth1 eth2 eth3; do
    docker exec "$1" ip link set "$interface" "$2"
  done
}

verify_node() {
  local other_ip=$worker_ip
  if [[ $role == worker ]]; then other_ip=$control_ip; fi
  ip -j -4 address show dev lo | jq -e --arg ip "$node_ip" \
    '[.[].addr_info[] | select(.scope == "global")] | length == 1 and .[0].local == $ip and .[0].prefixlen == 32' >/dev/null
  ip -d -j link show | jq -e 'all(.[]; .linkinfo.info_kind != "vrf" and .linkinfo.info_kind != "bridge")' >/dev/null
  vtysh -c 'show bgp ipv4 unicast summary json' |
    jq -e '
      .peers as $p | ($p["127.0.0.2"].state == "Established" and $p["127.0.0.2"].remoteAs == 65201)
      and all(["k8s-tor1","k8s-tor2"][]; $p[.].state == "Established" and $p[.].idType == "interface")
    ' >/dev/null
  check_default '["k8s-tor1","k8s-tor2"]' ip
  ip -j -4 route get fibmatch "$other_ip" | jq -e '.[0].dst == "default"' >/dev/null
  ping -c 2 -W 2 "$other_ip"
  ping -c 2 -W 2 "$client_ip"
}

fabric_traffic() {
  local interfaces=$1 tor address
  shift
  for tor in "$@"; do
    check_routes '["eth1","eth3"]' docker exec "$tor" ip -j -4 route show exact "$vip/32" || return 1
  done
  for address in "$control_ip" "$worker_ip" "$vip"; do
    check_routes "$interfaces" docker exec "$client" ip -j -4 route show exact "$address/32" || return 1
  done
  docker exec "$client" ping -c 2 -W 2 "$control_ip" &&
    docker exec "$client" ping -c 2 -W 2 "$worker_ip" &&
    docker exec "$client" wget -q -T 5 -O - "http://$vip/" | grep -Fx probe
}

wait_for_fabric_traffic() {
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if fabric_traffic "$@"; then return 0; fi
    sleep 2
  done
  return 1
}

verify_fabric() {
  local index surviving_tor
  check_peers "$client" '["eth1","eth2"]'
  for index in "${!tors[@]}"; do
    check_peers "${tors[index]}" '["eth1","eth2","eth3"]'
  done
  wait_for_fabric_traffic '["eth1","eth2"]' "${tors[@]}"
  if [[ $failover == --failover ]]; then
    trap 'for tor in "${tors[@]}"; do set_tor_links "$tor" up || true; done' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for index in "${!tors[@]}"; do
      surviving_tor=${tors[1 - index]}
      printf 'Testing failover with %s down\n' "${tors[index]}"
      set_tor_links "${tors[index]}" down
      wait_for_fabric_traffic "[\"eth$((2 - index))\"]" "$surviving_tor"
      set_tor_links "${tors[index]}" up
      wait_for_fabric_traffic '["eth1","eth2"]' "${tors[@]}"
    done
    trap - EXIT INT TERM
  fi
}

probe_info() {
  kubectl -n lab-probe get pods -l app=probe --field-selector "spec.nodeName=$1" -o json |
    jq -er '.items | select(length == 1) | .[0] | [.metadata.name, .status.podIP] | @tsv'
}

verify() {
  local control_pod control_pod_ip worker_pod worker_pod_ip worker_cilium result pod
  kubectl wait --for=condition=Ready --timeout=180s "node/$control_node" "node/$worker_node"
  if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
    echo 'kube-proxy DaemonSet must not be present.' >&2
    return 1
  fi
  kubectl -n lab-probe rollout status daemonset/probe --timeout=180s
  kubectl -n lab-probe wait --timeout=120s \
    --for="jsonpath={.status.loadBalancer.ingress[0].ip}=$vip" service/probe
  kubectl get node "$control_node" "$worker_node" -o json |
    jq -e --arg control "$control_ip" --arg worker "$worker_ip" '
      [.items[].status.addresses[] | select(.type == "InternalIP").address] | sort == [$control,$worker]
    ' >/dev/null
  result=$(probe_info "$control_node")
  IFS=$'\t' read -r control_pod control_pod_ip <<< "$result"
  result=$(probe_info "$worker_node")
  IFS=$'\t' read -r worker_pod worker_pod_ip <<< "$result"
  worker_cilium=$(kubectl -n kube-system get pods -l k8s-app=cilium \
    --field-selector "spec.nodeName=$worker_node,status.phase=Running" \
    -o json | jq -er '.items | select(length == 1) | .[0].metadata.name')

  verify_node
  check_default '["k8s-tor1","k8s-tor2"]' kubectl -n kube-system exec "$worker_cilium" -- ip
  for pod in "$control_pod" "$worker_pod"; do
    kubectl -n lab-probe exec "$pod" -- ping -c 2 -W 2 "$client_ip"
  done
  kubectl -n lab-probe exec "$control_pod" -- ping -c 2 -W 2 "$worker_pod_ip"
  kubectl -n lab-probe exec "$worker_pod" -- ping -c 2 -W 2 "$control_pod_ip"
}

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
  ip address del "$node_ip/32" dev lo 2>/dev/null || true
  if cmp -s networkd-cilium-lab.conf "$networkd_dropin"; then
    rm -f "$networkd_dropin"
    if systemctl is-active --quiet systemd-networkd; then
      systemctl restart systemd-networkd
    fi
  fi
  rm -f "$state/owned" "$state/init.yaml" "$state/frr.conf"
}

"${action//-/_}"
