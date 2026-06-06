#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local tmp
  local kvm_output
  local vmware_output
  local esxi_output
  local esxi_create_output
  local expected_vmware_guest_os

  tmp="$(make_temp_dir)"
  case "$(uname -m)" in
    aarch64|arm64)
      expected_vmware_guest_os="arm-ubuntu-64"
      ;;
    *)
      expected_vmware_guest_os="ubuntu-64"
      ;;
  esac
  kvm_output="$(STATE_ROOT="${tmp}/state" DRY_RUN_LOG="${tmp}/kvm.log" bash "${REPO_ROOT}/scripts/kvm-lab.sh" deploy --dry-run 2>&1)"
  assert_contains "${kvm_output}" "virt-install"
  assert_contains "${kvm_output}" "router_url=http://192.168.110.10:80/"
  assert_file_contains "${tmp}/state/kvm/seed-router/user-data" "virtual-network-delay-router-bootstrap"
  assert_file_contains "${tmp}/state/kvm/seed-router/network-config" "set-name: public0"
  assert_file_contains "${tmp}/state/kvm/seed-backend/network-config" "via: 192.168.111.10"
  assert_file_contains "${REPO_ROOT}/scripts/check-prerequisites.sh" "dnsmasq-base"
  assert_file_contains "${REPO_ROOT}/scripts/kvm-lab.sh" "grant_libvirt_storage_access"

  vmware_output="$(STATE_ROOT="${tmp}/state2" DRY_RUN_LOG="${tmp}/vmware.log" bash "${REPO_ROOT}/scripts/vmware-lab.sh" deploy --dry-run 2>&1)"
  assert_contains "${vmware_output}" "qemu-img convert -O qcow2"
  assert_contains "${vmware_output}" ".vmdk.qcow2.tmp"
  assert_contains "${vmware_output}" "qemu-img convert -O vmdk"
  assert_contains "${vmware_output}" "vmrun -T fusion start"
  assert_contains "${vmware_output}" "router_url=http://192.0.2.10:80/"
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" 'ethernet0.connectionType = "nat"'
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" 'ethernet1.connectionType = "hostonly"'
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" "guestOS = \"${expected_vmware_guest_os}\""
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" 'pciBridge4.virtualDev = "pcieRootPort"'
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" 'sata0:0.deviceType = "disk"'
  assert_file_contains "${tmp}/state2/vmware/vms/virtual-network-delay-router.vmwarevm/virtual-network-delay-router.vmx" 'sata0:1.deviceType = "cdrom-image"'
  assert_file_contains "${tmp}/state2/vmware/seed-router/user-data" "open-vm-tools"

  esxi_output="$(
    GOVC_URL="https://esxi.example/sdk" \
      GOVC_DATASTORE="datastore1" \
      ESXI_PUBLIC_NETWORK="VM Network" \
      ESXI_PRIVATE_NETWORK="vnd-private" \
      STATE_ROOT="${tmp}/state3" \
      DRY_RUN_LOG="${tmp}/esxi.log" \
      bash "${REPO_ROOT}/scripts/esxi-lab.sh" deploy --dry-run 2>&1
  )"
  assert_contains "${esxi_output}" "noble-server-cloudimg-amd64.img"
  assert_contains "${esxi_output}" "qemu-img convert -O vmdk -o subformat=streamOptimized"
  assert_contains "${esxi_output}" "govc datastore.mkdir -ds datastore1 virtual-network-delay/virtual-network-delay"
  assert_contains "${esxi_output}" "govc import.vmdk -ds datastore1 -force"
  assert_contains "${esxi_output}" "govc datastore.upload -ds datastore1"
  assert_contains "${esxi_output}" "govc vm.create -on=false -g ubuntu64Guest -firmware efi"
  assert_contains "${esxi_output}" "govc vm.network.add"
  assert_contains "${esxi_output}" "govc vm.power -on virtual-network-delay-router virtual-network-delay-backend"
  assert_contains "${esxi_output}" "govc vm.ip -a -v4 -n"
  assert_contains "${esxi_output}" "router_url=http://192.0.2.20:80/"
  assert_file_contains "${tmp}/state3/esxi/virtual-network-delay.env" "UBUNTU_IMAGE_ARCH=amd64"
  assert_file_contains "${tmp}/state3/esxi/seed-router/user-data" "open-vm-tools"
  assert_file_contains "${tmp}/state3/esxi/seed-router/network-config" "dhcp4: true"
  assert_file_contains "${tmp}/state3/esxi/seed-router/network-config" "172.31.202.10/24"
  assert_file_contains "${tmp}/state3/esxi/seed-backend/network-config" "via: 172.31.202.10"

  esxi_create_output="$(
    GOVC_URL="https://esxi.example/sdk" \
      GOVC_DATASTORE="datastore1" \
      ESXI_PUBLIC_NETWORK="vnd-public" \
      ESXI_PRIVATE_NETWORK="vnd-private" \
      ESXI_PUBLIC_VSWITCH="vnd-public-switch" \
      ESXI_PRIVATE_VSWITCH="vnd-private-switch" \
      ESXI_NETWORK_MODE=create \
      STATE_ROOT="${tmp}/state4" \
      bash "${REPO_ROOT}/scripts/esxi-lab.sh" deploy --dry-run 2>&1
  )"
  assert_contains "${esxi_create_output}" "govc host.vswitch.add vnd-public-switch"
  assert_contains "${esxi_create_output}" "govc host.vswitch.add vnd-private-switch"
  assert_contains "${esxi_create_output}" "govc host.portgroup.add -vswitch vnd-public-switch -vlan 0 vnd-public"
  assert_contains "${esxi_create_output}" "govc host.portgroup.add -vswitch vnd-private-switch -vlan 0 vnd-private"

  pass_test "kvm, vmware, and esxi dry-run rendering"
}

main "$@"
