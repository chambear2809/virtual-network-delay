#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift || true

PROVIDER="esxi"
set_provider_paths "${PROVIDER}"

ESXI_PUBLIC_NETWORK="${ESXI_PUBLIC_NETWORK:-}"
ESXI_PRIVATE_NETWORK="${ESXI_PRIVATE_NETWORK:-}"
ESXI_NETWORK_MODE="${ESXI_NETWORK_MODE:-reuse}"
ESXI_PUBLIC_VSWITCH="${ESXI_PUBLIC_VSWITCH:-}"
ESXI_PRIVATE_VSWITCH="${ESXI_PRIVATE_VSWITCH:-}"
ESXI_PUBLIC_VLAN_ID="${ESXI_PUBLIC_VLAN_ID:-0}"
ESXI_PRIVATE_VLAN_ID="${ESXI_PRIVATE_VLAN_ID:-0}"
ESXI_ROUTER_PRIVATE_IP="${ESXI_ROUTER_PRIVATE_IP:-172.31.202.10}"
ESXI_BACKEND_PRIVATE_IP="${ESXI_BACKEND_PRIVATE_IP:-172.31.202.20}"
ESXI_PRIVATE_PREFIX="${ESXI_PRIVATE_PREFIX:-24}"
UBUNTU_IMAGE_ARCH="${UBUNTU_IMAGE_ARCH:-amd64}"
VM_MEMORY_MB="${VM_MEMORY_MB:-1024}"
VM_VCPUS="${VM_VCPUS:-1}"
VM_DISK_SIZE="${VM_DISK_SIZE:-8G}"
DESTROY_YES="${DESTROY_YES:-false}"

ESXI_CREATED_PUBLIC_NETWORK="${ESXI_CREATED_PUBLIC_NETWORK:-}"
ESXI_CREATED_PRIVATE_NETWORK="${ESXI_CREATED_PRIVATE_NETWORK:-}"
ESXI_CREATED_PUBLIC_VSWITCH="${ESXI_CREATED_PUBLIC_VSWITCH:-}"
ESXI_CREATED_PRIVATE_VSWITCH="${ESXI_CREATED_PRIVATE_VSWITCH:-}"

usage() {
  cat <<'EOF'
Usage: esxi-lab.sh <deploy|status|destroy> [options]

Options:
  --lab-name <name>
  --create-networks       Create ESXi standard vSwitches and port groups
  --dry-run
  --yes
  --help

Required environment:
  GOVC_URL
  GOVC_DATASTORE
  ESXI_PUBLIC_NETWORK
  ESXI_PRIVATE_NETWORK

Create-network mode also requires:
  ESXI_PUBLIC_VSWITCH
  ESXI_PRIVATE_VSWITCH
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab-name)
        LAB_NAME="${2:?missing value for --lab-name}"
        set_provider_paths "${PROVIDER}"
        shift 2
        ;;
      --create-networks)
        ESXI_NETWORK_MODE=create
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --yes|-y)
        DESTROY_YES=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

require_esxi_cmds() {
  bool_is_true "${DRY_RUN}" && return 0
  local cmd
  for cmd in govc qemu-img curl ssh ssh-keygen scp; do
    require_cmd "${cmd}"
  done
  command -v cloud-localds >/dev/null 2>&1 \
    || command -v genisoimage >/dev/null 2>&1 \
    || command -v mkisofs >/dev/null 2>&1 \
    || command -v hdiutil >/dev/null 2>&1 \
    || fail "Need one NoCloud seed ISO tool: cloud-localds, genisoimage, mkisofs, or hdiutil."
}

validate_esxi_config() {
  [[ -n "${GOVC_URL:-}" ]] || fail "Missing GOVC_URL for ESXi/vCenter access."
  [[ -n "${GOVC_DATASTORE:-}" ]] || fail "Missing GOVC_DATASTORE for ESXi datastore placement."
  [[ -n "${ESXI_PUBLIC_NETWORK}" ]] || fail "Missing ESXI_PUBLIC_NETWORK port group name."
  [[ -n "${ESXI_PRIVATE_NETWORK}" ]] || fail "Missing ESXI_PRIVATE_NETWORK port group name."

  case "${ESXI_NETWORK_MODE}" in
    reuse)
      ;;
    create)
      [[ -n "${ESXI_PUBLIC_VSWITCH}" ]] || fail "Missing ESXI_PUBLIC_VSWITCH for ESXI_NETWORK_MODE=create."
      [[ -n "${ESXI_PRIVATE_VSWITCH}" ]] || fail "Missing ESXI_PRIVATE_VSWITCH for ESXI_NETWORK_MODE=create."
      [[ "${ESXI_PUBLIC_VLAN_ID}" =~ ^[0-9]+$ ]] || fail "ESXI_PUBLIC_VLAN_ID must be an integer VLAN ID."
      [[ "${ESXI_PRIVATE_VLAN_ID}" =~ ^[0-9]+$ ]] || fail "ESXI_PRIVATE_VLAN_ID must be an integer VLAN ID."
      ;;
    *)
      fail "ESXI_NETWORK_MODE must be reuse or create, got: ${ESXI_NETWORK_MODE}"
      ;;
  esac
}

esxi_remote_dir() {
  printf 'virtual-network-delay/%s\n' "${LAB_NAME}"
}

prepare_esxi_vmdk() {
  local source_image="$1"
  local output_disk="$2"
  local disk_size="$3"
  local temp_disk

  mkdir -p "$(dirname "${output_disk}")"
  if [[ -f "${output_disk}" ]]; then
    log "Reusing disk ${output_disk}"
    return 0
  fi

  temp_disk="${output_disk}.qcow2.tmp"
  run_cmd rm -f "${temp_disk}"
  run_cmd qemu-img convert -O qcow2 "${source_image}" "${temp_disk}"
  run_cmd qemu-img resize "${temp_disk}" "${disk_size}"
  run_cmd qemu-img convert -O vmdk -o subformat=streamOptimized "${temp_disk}" "${output_disk}"
  run_cmd rm -f "${temp_disk}"
}

render_seed_files() {
  local role="$1"
  local seed_dir="${STATE_DIR}/seed-${role}"
  local ssh_public_key="$2"

  mkdir -p "${seed_dir}"
  if [[ "${role}" == "router" ]]; then
    write_router_user_data "${seed_dir}/user-data" "esxi" "${ESXI_BACKEND_PRIVATE_IP}" "${BACKEND_PORT}" "${PUBLIC_PORT}" "${ssh_public_key}"
    write_metadata "${seed_dir}/meta-data" "${LAB_NAME}-esxi-router" "${LAB_NAME}-router"
    write_vmware_router_network_config "${seed_dir}/network-config" \
      "${ESXI_ROUTER_PUBLIC_MAC}" "${ESXI_ROUTER_PRIVATE_MAC}" \
      "${ESXI_ROUTER_PRIVATE_IP}" "${ESXI_PRIVATE_PREFIX}"
  else
    write_backend_user_data "${seed_dir}/user-data" "${ssh_public_key}"
    write_metadata "${seed_dir}/meta-data" "${LAB_NAME}-esxi-backend" "${LAB_NAME}-backend"
    write_vmware_backend_network_config "${seed_dir}/network-config" \
      "${ESXI_BACKEND_PRIVATE_MAC}" "${ESXI_BACKEND_PRIVATE_IP}" \
      "${ESXI_PRIVATE_PREFIX}" "${ESXI_ROUTER_PRIVATE_IP}"
  fi
}

create_esxi_vswitch() {
  local vswitch_name="$1"
  local created_var="$2"

  if ! bool_is_true "${DRY_RUN}" && govc host.vswitch.info 2>/dev/null | awk -F: -v name="${vswitch_name}" '
    $1 == "Name" {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == name) {
        found = 1
      }
    }
    END { exit !found }
  '; then
    log "Reusing ESXi vSwitch ${vswitch_name}"
    return 0
  fi

  run_cmd govc host.vswitch.add "${vswitch_name}"
  printf -v "${created_var}" '%s' "${vswitch_name}"
}

create_esxi_portgroup() {
  local portgroup_name="$1"
  local vswitch_name="$2"
  local vlan_id="$3"
  local created_var="$4"

  if ! bool_is_true "${DRY_RUN}" && govc host.portgroup.info 2>/dev/null | awk -F: -v name="${portgroup_name}" '
    $1 == "Name" {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == name) {
        found = 1
      }
    }
    END { exit !found }
  '; then
    log "Reusing ESXi port group ${portgroup_name}"
    return 0
  fi

  run_cmd govc host.portgroup.add -vswitch "${vswitch_name}" -vlan "${vlan_id}" "${portgroup_name}"
  printf -v "${created_var}" '%s' "${portgroup_name}"
}

create_esxi_networks() {
  [[ "${ESXI_NETWORK_MODE}" == "create" ]] || return 0

  create_esxi_vswitch "${ESXI_PUBLIC_VSWITCH}" ESXI_CREATED_PUBLIC_VSWITCH
  if [[ "${ESXI_PRIVATE_VSWITCH}" != "${ESXI_PUBLIC_VSWITCH}" ]]; then
    create_esxi_vswitch "${ESXI_PRIVATE_VSWITCH}" ESXI_CREATED_PRIVATE_VSWITCH
  fi

  create_esxi_portgroup "${ESXI_PUBLIC_NETWORK}" "${ESXI_PUBLIC_VSWITCH}" "${ESXI_PUBLIC_VLAN_ID}" ESXI_CREATED_PUBLIC_NETWORK
  create_esxi_portgroup "${ESXI_PRIVATE_NETWORK}" "${ESXI_PRIVATE_VSWITCH}" "${ESXI_PRIVATE_VLAN_ID}" ESXI_CREATED_PRIVATE_NETWORK
}

upload_esxi_artifacts() {
  local remote_dir="$1"

  run_cmd govc datastore.mkdir -ds "${GOVC_DATASTORE}" "${remote_dir}"
  run_cmd govc import.vmdk -ds "${GOVC_DATASTORE}" -force "${STATE_DIR}/${LAB_NAME}-router.vmdk" "${remote_dir}"
  run_cmd govc import.vmdk -ds "${GOVC_DATASTORE}" -force "${STATE_DIR}/${LAB_NAME}-backend.vmdk" "${remote_dir}"
  run_cmd govc datastore.upload -ds "${GOVC_DATASTORE}" "${STATE_DIR}/seed-router.iso" "${remote_dir}/seed-router.iso"
  run_cmd govc datastore.upload -ds "${GOVC_DATASTORE}" "${STATE_DIR}/seed-backend.iso" "${remote_dir}/seed-backend.iso"
}

create_esxi_vm() {
  local role="$1"
  local vm_name="$2"
  local network_name="$3"
  local mac_address="$4"
  local remote_dir="$5"
  local remote_disk="${remote_dir}/${LAB_NAME}-${role}.vmdk"
  local remote_iso="${remote_dir}/seed-${role}.iso"

  run_cmd govc vm.create \
    -on=false \
    -g ubuntu64Guest \
    -firmware efi \
    -m "${VM_MEMORY_MB}" \
    -c "${VM_VCPUS}" \
    -ds "${GOVC_DATASTORE}" \
    -disk.controller pvscsi \
    -disk-datastore "${GOVC_DATASTORE}" \
    -disk "${remote_disk}" \
    -link=false \
    -iso-datastore "${GOVC_DATASTORE}" \
    -iso "${remote_iso}" \
    -net "${network_name}" \
    -net.adapter vmxnet3 \
    -net.address "${mac_address}" \
    "${vm_name}"
}

add_esxi_network() {
  local vm_name="$1"
  local network_name="$2"
  local mac_address="$3"

  run_cmd govc vm.network.add \
    -vm "${vm_name}" \
    -net "${network_name}" \
    -net.adapter vmxnet3 \
    -net.address "${mac_address}"
}

wait_for_esxi_ip() {
  local vm_name="$1"
  local public_mac="$2"
  local timeout="${3:-420s}"
  local ip

  if bool_is_true "${DRY_RUN}"; then
    record_dry_run govc vm.ip -a -v4 -n "${public_mac}" -wait "${timeout}" "${vm_name}" >&2
    printf '%s\n' "${ROUTER_HOST:-192.0.2.20}"
    return 0
  fi

  ip="$(govc vm.ip -a -v4 -n "${public_mac}" -wait "${timeout}" "${vm_name}" \
    | tr ',' '\n' \
    | awk '/^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ { print; exit }')"

  if [[ -z "${ip}" && -n "${ROUTER_HOST}" ]]; then
    warn "govc did not report a router IP; using explicit ROUTER_HOST=${ROUTER_HOST}."
    ip="${ROUTER_HOST}"
  fi

  [[ -n "${ip}" ]] || fail "Timed out waiting for ESXi router IP via govc vm.ip."
  printf '%s\n' "${ip}"
}

record_esxi_state() {
  local router_ip="$1"
  local remote_dir="$2"

  state_set ESXI_ROUTER_VM "${ESXI_ROUTER_VM}"
  state_set ESXI_BACKEND_VM "${ESXI_BACKEND_VM}"
  state_set ESXI_REMOTE_DIR "${remote_dir}"
  state_set ESXI_NETWORK_MODE "${ESXI_NETWORK_MODE}"
  state_set ESXI_PUBLIC_NETWORK "${ESXI_PUBLIC_NETWORK}"
  state_set ESXI_PRIVATE_NETWORK "${ESXI_PRIVATE_NETWORK}"
  state_set ESXI_ROUTER_PUBLIC_MAC "${ESXI_ROUTER_PUBLIC_MAC}"
  state_set ESXI_ROUTER_PRIVATE_MAC "${ESXI_ROUTER_PRIVATE_MAC}"
  state_set ESXI_BACKEND_PRIVATE_MAC "${ESXI_BACKEND_PRIVATE_MAC}"
  state_set ESXI_CREATED_PUBLIC_NETWORK "${ESXI_CREATED_PUBLIC_NETWORK}"
  state_set ESXI_CREATED_PRIVATE_NETWORK "${ESXI_CREATED_PRIVATE_NETWORK}"
  state_set ESXI_CREATED_PUBLIC_VSWITCH "${ESXI_CREATED_PUBLIC_VSWITCH}"
  state_set ESXI_CREATED_PRIVATE_VSWITCH "${ESXI_CREATED_PRIVATE_VSWITCH}"
  state_set ROUTER_HOST "${router_ip}"
  state_set ROUTER_PUBLIC_URL "http://${router_ip}:${PUBLIC_PORT}/"
  state_set ROUTER_SSH_USER "${ROUTER_SSH_USER}"
  state_set BACKEND_HOST "${ESXI_BACKEND_PRIVATE_IP}"
  state_set BACKEND_PORT "${BACKEND_PORT}"
  state_set PUBLIC_PORT "${PUBLIC_PORT}"
}

deploy_lab() {
  local image_file
  local ssh_public_key
  local remote_dir
  local router_ip

  require_esxi_cmds
  validate_esxi_config
  validate_port backend-port "${BACKEND_PORT}"
  validate_port public-port "${PUBLIC_PORT}"
  mkdir -p "${STATE_DIR}"
  state_note_defaults
  state_set UBUNTU_IMAGE_ARCH "${UBUNTU_IMAGE_ARCH}"
  ensure_ssh_key
  ssh_public_key="$(ssh_public_key_content)"

  ESXI_ROUTER_VM="${ESXI_ROUTER_VM:-${LAB_NAME}-router}"
  ESXI_BACKEND_VM="${ESXI_BACKEND_VM:-${LAB_NAME}-backend}"
  ESXI_ROUTER_PUBLIC_MAC="${ESXI_ROUTER_PUBLIC_MAC:-$(mac_from_token 00:50:56 "${LAB_NAME}-esxi-router-public" 63)}"
  ESXI_ROUTER_PRIVATE_MAC="${ESXI_ROUTER_PRIVATE_MAC:-$(mac_from_token 00:50:56 "${LAB_NAME}-esxi-router-private" 63)}"
  ESXI_BACKEND_PRIVATE_MAC="${ESXI_BACKEND_PRIVATE_MAC:-$(mac_from_token 00:50:56 "${LAB_NAME}-esxi-backend-private" 63)}"
  remote_dir="$(esxi_remote_dir)"

  create_esxi_networks

  image_file="$(download_ubuntu_image)"
  prepare_esxi_vmdk "${image_file}" "${STATE_DIR}/${LAB_NAME}-router.vmdk" "${VM_DISK_SIZE}"
  prepare_esxi_vmdk "${image_file}" "${STATE_DIR}/${LAB_NAME}-backend.vmdk" "${VM_DISK_SIZE}"

  render_seed_files router "${ssh_public_key}"
  render_seed_files backend "${ssh_public_key}"
  create_seed_iso "${STATE_DIR}/seed-router" "${STATE_DIR}/seed-router.iso"
  create_seed_iso "${STATE_DIR}/seed-backend" "${STATE_DIR}/seed-backend.iso"

  upload_esxi_artifacts "${remote_dir}"
  create_esxi_vm router "${ESXI_ROUTER_VM}" "${ESXI_PUBLIC_NETWORK}" "${ESXI_ROUTER_PUBLIC_MAC}" "${remote_dir}"
  add_esxi_network "${ESXI_ROUTER_VM}" "${ESXI_PRIVATE_NETWORK}" "${ESXI_ROUTER_PRIVATE_MAC}"
  create_esxi_vm backend "${ESXI_BACKEND_VM}" "${ESXI_PRIVATE_NETWORK}" "${ESXI_BACKEND_PRIVATE_MAC}" "${remote_dir}"

  run_cmd govc vm.power -on "${ESXI_ROUTER_VM}" "${ESXI_BACKEND_VM}"
  router_ip="$(wait_for_esxi_ip "${ESXI_ROUTER_VM}" "${ESXI_ROUTER_PUBLIC_MAC}" 420s)"

  record_esxi_state "${router_ip}" "${remote_dir}"
  wait_for_cloud_init "${router_ip}" "${ROUTER_SSH_USER}" "${SSH_PRIVATE_KEY_FILE}" 420
  ROUTER_PUBLIC_URL="http://${router_ip}:${PUBLIC_PORT}/"
  wait_for_http_url "${ROUTER_PUBLIC_URL}" 240
  log "ESXi lab is ready."
  print_lab_summary "${PROVIDER}"
}

status_lab() {
  state_load
  require_esxi_cmds
  run_cmd govc vm.info "${ESXI_ROUTER_VM:-${LAB_NAME}-router}" "${ESXI_BACKEND_VM:-${LAB_NAME}-backend}"
  print_lab_summary "${PROVIDER}"
}

destroy_lab() {
  state_load
  require_esxi_cmds
  bool_is_true "${DESTROY_YES}" || fail "Refusing to destroy without --yes."
  [[ -n "${GOVC_URL:-}" ]] || fail "Missing GOVC_URL for ESXi/vCenter access."
  [[ -n "${GOVC_DATASTORE:-}" ]] || fail "Missing GOVC_DATASTORE for ESXi datastore cleanup."

  [[ -n "${ESXI_ROUTER_VM:-}" ]] && run_cmd govc vm.power -off -force "${ESXI_ROUTER_VM}" || true
  [[ -n "${ESXI_BACKEND_VM:-}" ]] && run_cmd govc vm.power -off -force "${ESXI_BACKEND_VM}" || true
  [[ -n "${ESXI_ROUTER_VM:-}" ]] && run_cmd govc vm.destroy "${ESXI_ROUTER_VM}" || true
  [[ -n "${ESXI_BACKEND_VM:-}" ]] && run_cmd govc vm.destroy "${ESXI_BACKEND_VM}" || true
  [[ -n "${ESXI_REMOTE_DIR:-}" ]] && run_cmd govc datastore.rm -ds "${GOVC_DATASTORE}" "${ESXI_REMOTE_DIR}" || true

  if [[ "${ESXI_NETWORK_MODE:-reuse}" == "create" ]]; then
    [[ -n "${ESXI_CREATED_PUBLIC_NETWORK:-}" ]] && run_cmd govc host.portgroup.remove "${ESXI_CREATED_PUBLIC_NETWORK}" || true
    [[ -n "${ESXI_CREATED_PRIVATE_NETWORK:-}" ]] && run_cmd govc host.portgroup.remove "${ESXI_CREATED_PRIVATE_NETWORK}" || true
    [[ -n "${ESXI_CREATED_PRIVATE_VSWITCH:-}" ]] && run_cmd govc host.vswitch.remove "${ESXI_CREATED_PRIVATE_VSWITCH}" || true
    [[ -n "${ESXI_CREATED_PUBLIC_VSWITCH:-}" ]] && run_cmd govc host.vswitch.remove "${ESXI_CREATED_PUBLIC_VSWITCH}" || true
  fi

  run_cmd rm -rf "${STATE_DIR}"
}

main() {
  load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
  refresh_derived_defaults
  PROVIDER="esxi"
  set_provider_paths "${PROVIDER}"
  parse_args "$@"
  [[ -n "${ACTION}" ]] || fail "Missing action. Use deploy, status, or destroy."

  case "${ACTION}" in
    deploy)
      deploy_lab
      ;;
    status)
      status_lab
      ;;
    destroy)
      destroy_lab
      ;;
    *)
      fail "Unknown action: ${ACTION}"
      ;;
  esac
}

main "$@"
