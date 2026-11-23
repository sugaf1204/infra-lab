#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

export KUBECONFIG=/etc/kubernetes/admin.conf
export CLAB_RUNTIME=docker DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT

cri=unix:///run/containerd-cilium-lab/containerd.sock

fabric_nics() {
  for i in 1 2; do
    ../common/tor-nic.sh "$1" "k8s-ctl-tor$i" "clab-cilium-l3-tor$i" eth1
    ../common/tor-nic.sh "$1" "k8s-tor$i" "clab-cilium-l3-tor$i" eth3
  done
}

case "${1:-}" in
  fabric-up)
    ansible-playbook -i localhost, -c local ../common/render-fabric.yml -e "lab_dir=$PWD"
    fabric_nics detach
    containerlab deploy --topo topology.clab.yml --reconfigure
    fabric_nics attach
    ;;
  fabric-down)
    fabric_nics detach
    containerlab destroy --topo topology.clab.yml --cleanup
    ;;
  up)
    ansible-playbook -i localhost, -c local host.yml
    if [[ ! -f /etc/kubernetes/admin.conf ]]; then
      KUBERNETES_VERSION=$(kubeadm version -o short) envsubst '${KUBERNETES_VERSION}' < kubeadm-init.yaml.in > /tmp/kubeadm-init.yaml
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u no_proxy -u NO_PROXY \
        kubeadm init --config /tmp/kubeadm-init.yaml --skip-token-print
      rm -f /tmp/kubeadm-init.yaml
    fi
    kubectl label node cilium-l3-node node.kubernetes.io/exclude-from-external-load-balancers- || true
    helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
      --version 1.21.0-pre.4 --namespace kube-system --values cilium-values.yaml --wait --timeout 10m
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
    kubectl apply -f bgp.yaml -f probes.yaml
    ;;
  join-config)
    JOIN_TOKEN=$(kubeadm token create --ttl 20m) \
    CA_HASH=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -pubkey -noout |
      openssl pkey -pubin -outform DER | openssl dgst -sha256 -r | awk '{print $1}') \
      envsubst '${JOIN_TOKEN} ${CA_HASH}' < kubeadm-join.yaml.in
    ;;
  join)
    ansible-playbook -i localhost, -c local host.yml
    if [[ ! -f /etc/kubernetes/kubelet.conf ]]; then
      cat > /tmp/kubeadm-join.yaml
      kubeadm join --config /tmp/kubeadm-join.yaml
      rm -f /tmp/kubeadm-join.yaml
    fi
    ;;
  down)
    kubeadm reset -f --cri-socket "$cri" || true
    rm -f /etc/cni/net.d/05-cilium.conflist /etc/netplan/80-infra-lab-data.yaml /etc/sysctl.d/80-infra-lab-routing.conf
    systemctl stop frr.service || true
    netplan apply
    ;;
  *)
    echo "Usage: $0 {fabric-up|fabric-down|up|join-config|join|down}" >&2
    exit 2
    ;;
esac
