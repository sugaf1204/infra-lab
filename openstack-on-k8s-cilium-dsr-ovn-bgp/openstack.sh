#!/usr/bin/env bash
# openstack-helm による OpenStack 2026.2（ML2/OVN + ovn-bgp service plugin）の導入と撤去。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

lab=osk-bgp
export KUBECONFIG=$PWD/$lab.kubeconfig
osh_commit=1c45752
osh=$PWD/.lab-state/openstack-helm
ns=openstack

label_nodes() {
  kubectl label node --overwrite -l lab.infra/group=openstack-controller \
    openstack-control-plane=enabled openstack-network-node=enabled
  kubectl label node --overwrite -l lab.infra/group=openstack-compute \
    openstack-compute-node=enabled openvswitch=enabled
}

prep_nodes() {
  kubectl get nodes -l lab.infra/group=openstack-compute \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address} {.metadata.annotations.openstack-helm/ovn-system-id}{"\n"}{end}' |
    while read -r node address system_id; do ./node-prep.sh "$node" "$address" "$system_id"; done
}

ovs_all() {
  local pod
  for pod in $(kubectl -n "$ns" get pods -l application=openvswitch,component=server -o name); do
    kubectl -n "$ns" exec "$pod" -c openvswitch-vswitchd -- "$@"
  done
}

kick_agent() {
  # ovn-bgp エージェント拡張は、起動時にすでに存在する peer bridge にはフローを入れない
  # （Bridge 行の作成・更新イベントが契機）。行を更新して再設定を促す。
  ovs_all sh -c 'ovs-vsctl set bridge br-bgp-0 external-ids:lab-kick="$(date +%s)"'
}

chart() {
  local name=$1
  shift
  helm dependency build "$osh/$name" >/dev/null
  local values=()
  [[ -e $osh/values_overrides/$name/2026.2-ubuntu_resolute.yaml ]] &&
    values+=(--values "$osh/values_overrides/$name/2026.2-ubuntu_resolute.yaml")
  [[ -e openstack/$name.yaml ]] && values+=(--values "openstack/$name.yaml")
  helm upgrade --install "$name" "$osh/$name" --namespace "$ns" --timeout 20m "${values[@]}" "$@"
}

wait_pods() {
  # Job の完了と Pod の Ready を待つ（helm osh wait-for-pods 相当）。
  local deadline=$((SECONDS + ${1:-1200}))
  while ((SECONDS < deadline)); do
    if ! kubectl -n "$ns" get pods --no-headers 2>/dev/null |
      awk '$3 != "Completed" { split($2, r, "/"); if ($3 != "Running" || r[1] != r[2]) bad = 1 } END { exit !bad }'; then
      return 0
    fi
    sleep 10
  done
  kubectl -n "$ns" get pods | grep -Ev 'Completed|Running' >&2 || true
  return 1
}

case "${1:-}" in
  up)
    if [[ ! -d $osh/.git ]]; then
      mkdir -p .lab-state
      git clone -q https://opendev.org/openstack/openstack-helm.git "$osh"
    fi
    git -C "$osh" checkout -q "$osh_commit"
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
    label_nodes
    prep_nodes

    chart rabbitmq
    chart mariadb
    chart memcached
    wait_pods
    chart keystone
    wait_pods
    chart glance
    chart placement
    chart openvswitch
    kubectl -n "$ns" rollout status daemonset/openvswitch --timeout=10m
    # ovn-bgp エージェント拡張が参照する OVS external-ids。OSH の ovn チャートは設定しないためここで入れる。
    ovs_all ovs-vsctl set open . \
      external-ids:neutron-bgp-peer-bridges=br-bgp-0 external-ids:neutron-bgp-interconnect-bridge=br-ex
    # br-bgp-0 の「NIC」はホストカーネルにつながる veth（ovn-up0）。対向はホストの ovn-host0。
    # ovn-bgp エージェント拡張は OpenFlow10 でフローを入れるので、プロトコルを限定しない。
    ovs_all ovs-vsctl --may-exist add-br br-ex -- --may-exist add-br br-bgp-0 -- --may-exist add-port br-bgp-0 ovn-up0
    chart ovn
    kubectl -n "$ns" rollout status daemonset/ovn-controller-default --timeout=10m
    # br-bgp-0 ができたので、chassis ルーター用の外向きデフォルト（テーブル 10）を入れる。
    prep_nodes
    chart libvirt
    chart nova
    chart neutron
    wait_pods 1800
    kick_agent
    ;;
  kick)
    kick_agent
    ;;
  down)
    for release in neutron nova libvirt ovn openvswitch placement glance keystone memcached mariadb rabbitmq; do
      helm uninstall "$release" --namespace "$ns" || true
    done
    kubectl delete namespace "$ns" --wait=false || true
    ;;
  *)
    echo "Usage: $0 {up|kick|down}" >&2
    exit 2
    ;;
esac
