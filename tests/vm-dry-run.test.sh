#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local tmp
  local kvm_output
  local vmware_output

  tmp="$(make_temp_dir)"
  kvm_output="$(STATE_ROOT="${tmp}/state" DRY_RUN_LOG="${tmp}/kvm.log" bash "${REPO_ROOT}/scripts/kvm-lab.sh" deploy --dry-run 2>&1)"
  assert_contains "${kvm_output}" "virt-install"
  assert_contains "${kvm_output}" "router_url=http://192.168.110.10:80/"
  assert_file_contains "${tmp}/state/kvm/seed-router/user-data" "virtual-network-delay-router-bootstrap"
  assert_file_contains "${tmp}/state/kvm/seed-router/network-config" "set-name: public0"
  assert_file_contains "${tmp}/state/kvm/seed-backend/network-config" "via: 192.168.111.10"

  vmware_output="$(STATE_ROOT="${tmp}/state2" DRY_RUN_LOG="${tmp}/vmware.log" bash "${REPO_ROOT}/scripts/vmware-lab.sh" deploy --dry-run 2>&1)"
  assert_contains "${vmware_output}" "vmrun -T fusion start"
  assert_contains "${vmware_output}" "router_url=http://192.0.2.10:80/"
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" 'ethernet0.connectionType = "nat"'
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" 'ethernet1.connectionType = "hostonly"'
  assert_file_contains "${tmp}/state2/vmware/seed-router/user-data" "open-vm-tools"

  pass_test "kvm and vmware dry-run rendering"
}

main "$@"
