#!/usr/bin/env bash
# 撤去から構築・検証までを通しで実行する（スクリプトだけで再現できることの確認用）。
set -euxo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./openstack.sh down || true
./lab.sh down
./lab.sh up
./openstack.sh up
./vm.sh up
./lab.sh workloads
./verify.sh --failover
./verify.sh --withdraw
