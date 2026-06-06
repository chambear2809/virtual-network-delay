#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local tmp
  local output
  local status
  local command_dir

  tmp="$(make_temp_dir)"

  set +e
  output="$(
    GOVC_DATASTORE="datastore1" \
      ESXI_PUBLIC_NETWORK="VM Network" \
      ESXI_PRIVATE_NETWORK="vnd-private" \
      STATE_ROOT="${tmp}/state-missing-url" \
      bash "${REPO_ROOT}/scripts/esxi-lab.sh" deploy --dry-run 2>&1
  )"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail_test "ESXi deploy should require GOVC_URL"
  assert_contains "${output}" "Missing GOVC_URL"

  set +e
  output="$(
    GOVC_URL="https://esxi.example/sdk" \
      GOVC_DATASTORE="datastore1" \
      STATE_ROOT="${tmp}/state-missing-network" \
      bash "${REPO_ROOT}/scripts/esxi-lab.sh" deploy --dry-run 2>&1
  )"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail_test "ESXi deploy should require port groups"
  assert_contains "${output}" "Missing ESXI_PUBLIC_NETWORK"

  set +e
  output="$(
    GOVC_URL="https://esxi.example/sdk" \
      GOVC_DATASTORE="datastore1" \
      ESXI_PUBLIC_NETWORK="vnd-public" \
      ESXI_PRIVATE_NETWORK="vnd-private" \
      ESXI_NETWORK_MODE=create \
      STATE_ROOT="${tmp}/state-missing-vswitch" \
      bash "${REPO_ROOT}/scripts/esxi-lab.sh" deploy --dry-run 2>&1
  )"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail_test "ESXi create mode should require vSwitch names"
  assert_contains "${output}" "Missing ESXI_PUBLIC_VSWITCH"

  command_dir="${tmp}/commands"
  mkdir -p "${command_dir}"
  ln -s "$(command -v dirname)" "${command_dir}/dirname"
  ln -s "$(command -v pwd)" "${command_dir}/pwd"

  set +e
  output="$(PATH="${command_dir}" /bin/bash "${REPO_ROOT}/scripts/check-prerequisites.sh" --provider esxi 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail_test "ESXi prerequisites should require govc"
  assert_contains "${output}" "Missing required command: govc"

  mkdir -p "${tmp}/destroy-state/esxi"
  cat > "${tmp}/destroy-state/esxi/virtual-network-delay.env" <<'EOF'
LAB_NAME=virtual-network-delay
PROVIDER=esxi
ESXI_ROUTER_VM=virtual-network-delay-router
ESXI_BACKEND_VM=virtual-network-delay-backend
ESXI_REMOTE_DIR=virtual-network-delay/virtual-network-delay
ESXI_NETWORK_MODE=create
ESXI_CREATED_PUBLIC_NETWORK=vnd-public
ESXI_CREATED_PRIVATE_NETWORK=vnd-private
ESXI_CREATED_PUBLIC_VSWITCH=vnd-public-switch
ESXI_CREATED_PRIVATE_VSWITCH=vnd-private-switch
EOF

  output="$(
    GOVC_URL="https://esxi.example/sdk" \
      GOVC_DATASTORE="datastore1" \
      STATE_ROOT="${tmp}/destroy-state" \
      bash "${REPO_ROOT}/scripts/esxi-lab.sh" destroy --yes --dry-run 2>&1
  )"
  assert_contains "${output}" "govc vm.power -off -force virtual-network-delay-router"
  assert_contains "${output}" "govc vm.destroy virtual-network-delay-router"
  assert_contains "${output}" "govc datastore.rm -ds datastore1 virtual-network-delay/virtual-network-delay"
  assert_contains "${output}" "govc host.portgroup.remove vnd-public"
  assert_contains "${output}" "govc host.vswitch.remove vnd-private-switch"

  pass_test "esxi provider validation and destroy dry-run"
}

main "$@"
