#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local apply_output
  local demo_output
  local destroy_output
  local destroy_status
  local tmp

  tmp="$(make_temp_dir)"

  apply_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/backend-wire.sh" apply --provider docker --lab-name demo-a --protocol http --backend-host api.internal --backend-port 8081 --public-port 80 --dry-run)"
  assert_contains "${apply_output}" "install\\ HAProxy\\ config\\ from\\ stdin"
  assert_contains "${apply_output}" "-p demo-a"

  apply_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/backend-wire.sh" apply --provider vmware --protocol tcp --backend-host 172.31.201.20 --backend-port 9000 --public-port 9000 --router-host 192.0.2.10 --ssh-key "${tmp}/id_ed25519" --dry-run)"
  assert_contains "${apply_output}" "scp"
  assert_contains "${apply_output}" "ssh"
  assert_contains "${apply_output}" "sudo\\ haproxy\\ -c"

  apply_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/backend-wire.sh" apply --provider esxi --protocol tcp --backend-host 172.31.202.20 --backend-port 9000 --public-port 9000 --router-host 192.0.2.20 --ssh-key "${tmp}/id_ed25519" --dry-run)"
  assert_contains "${apply_output}" "scp"
  assert_contains "${apply_output}" "ssh"
  assert_contains "${apply_output}" "sudo\\ haproxy\\ -c"

  demo_output="$(STATE_ROOT="${tmp}/demo-state" bash "${REPO_ROOT}/scripts/demo-latency.sh" --provider docker --lab-name demo-a --public-port 18082 --delay-ms 125 --jitter-ms 5 --loss-pct 0 --restore-delay --dry-run)"
  assert_contains "${demo_output}" "router_url=http://127.0.0.1:18082/"
  assert_contains "${demo_output}" "planned_validate_command=bash scripts/validate-router-delay.sh validate --provider docker --lab-name demo-a --delay-ms 125 --jitter-ms 5 --loss-pct 0 --restore-delay"

  demo_output="$(
    GOVC_URL="https://esxi.example/sdk" \
      GOVC_DATASTORE="datastore1" \
      ESXI_PUBLIC_NETWORK="VM Network" \
      ESXI_PRIVATE_NETWORK="vnd-private" \
      STATE_ROOT="${tmp}/esxi-demo-state" \
      bash "${REPO_ROOT}/scripts/demo-latency.sh" --provider esxi --lab-name demo-esxi --delay-ms 125 --jitter-ms 5 --loss-pct 0 --restore-delay --dry-run 2>&1
  )"
  assert_contains "${demo_output}" "govc vm.create"
  assert_contains "${demo_output}" "router_url=http://192.0.2.20:80/"
  assert_contains "${demo_output}" "planned_validate_command=bash scripts/validate-router-delay.sh validate --provider esxi --lab-name demo-esxi --delay-ms 125 --jitter-ms 5 --loss-pct 0 --restore-delay"

  set +e
  destroy_output="$(bash "${REPO_ROOT}/scripts/destroy-virtual-network-delay.sh" --provider docker 2>&1)"
  destroy_status=$?
  set -e
  [[ "${destroy_status}" -ne 0 ]] || fail_test "destroy wrapper should require --yes"
  assert_contains "${destroy_output}" "Refusing to destroy without --yes"

  pass_test "command workflow dry-runs and safety checks"
}

main "$@"
