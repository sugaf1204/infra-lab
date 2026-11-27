#!/usr/bin/env bash
# flat provider network と、各 compute に 1 台ずつのテナント VM を作成・削除する。
# VM は TCP/80 に応答するだけで、L4LB・DSR・VIP を一切知らない。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

export KUBECONFIG=$PWD/osk-bgp.kubeconfig
ns=openstack

os() {
  kubectl -n "$ns" exec -i deploy/osc -- openstack "$@"
}

client_up() {
  kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: osc, namespace: openstack}
spec:
  selector: {matchLabels: {app: osc}}
  template:
    metadata: {labels: {app: osc}}
    spec:
      nodeSelector: {openstack-control-plane: enabled}
      containers:
        - name: osc
          image: quay.io/airshipit/openstack-client:2026.2-ubuntu_resolute
          command: [sleep, infinity]
          env:
            - {name: OS_AUTH_URL, value: "http://keystone-api.openstack.svc.cluster.local:5000/v3"}
            - {name: OS_USERNAME, value: admin}
            - {name: OS_PASSWORD, value: password}
            - {name: OS_PROJECT_NAME, value: admin}
            - {name: OS_USER_DOMAIN_NAME, value: default}
            - {name: OS_PROJECT_DOMAIN_NAME, value: default}
            - {name: OS_REGION_NAME, value: RegionOne}
            - {name: OS_INTERFACE, value: internal}
            - {name: OS_IDENTITY_API_VERSION, value: "3"}
YAML
  kubectl -n "$ns" rollout status deploy/osc --timeout=300s
}

# name compute-host fixed-ip
vms=(
  "vm1 osk-bgp-worker5 10.250.0.11"
  "vm2 osk-bgp-worker6 10.250.0.12"
)

case "${1:-}" in
  up)
    client_up
    os network show provider >/dev/null 2>&1 || os network create provider \
      --provider-network-type flat --provider-physical-network public
    os subnet show provider-v4 >/dev/null 2>&1 || os subnet create provider-v4 --network provider \
      --subnet-range 10.250.0.0/24 --gateway 10.250.0.1 --dhcp
    if ! os security group show web >/dev/null 2>&1; then
      os security group create web
      os security group rule create web --ingress --protocol icmp
      os security group rule create web --ingress --protocol tcp --dst-port 80
    fi
    os flavor show lab.tiny >/dev/null 2>&1 || os flavor create lab.tiny --vcpus 1 --ram 256 --disk 1
    image=$(os image list -f value -c Name | grep -i cirros | head -1)
    for vm in "${vms[@]}"; do
      read -r name host ip <<< "$vm"
      os server show "$name" >/dev/null 2>&1 && continue
      os port show "$name" >/dev/null 2>&1 || os port create "$name" --network provider \
        --fixed-ip "subnet=provider-v4,ip-address=$ip" --security-group web
      kubectl -n "$ns" exec -i deploy/osc -- sh -c 'cat > /tmp/user-data' <<'USERDATA'
#!/bin/sh
# 接続ごとにホスト名を返すだけの HTTP 応答。
while true; do
  printf 'HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nvm=%s\n' "$(hostname)" | nc -l -p 80
done >/dev/null 2>&1 &
USERDATA
      os server create "$name" --image "$image" --flavor lab.tiny --port "$name" \
        --availability-zone "nova:$host" --config-drive true --user-data /tmp/user-data --wait
    done
    os server list --long -c Name -c Status -c Host -c Networks
    ;;
  down)
    for vm in "${vms[@]}"; do
      read -r name _ <<< "$vm"
      os server delete --wait "$name" || true
      os port delete "$name" || true
    done
    ;;
  delete)
    os server delete --wait "$2"
    ;;
  os)
    shift
    os "$@"
    ;;
  *)
    echo "Usage: $0 {up|down|delete NAME|os ARGS...}" >&2
    exit 2
    ;;
esac
