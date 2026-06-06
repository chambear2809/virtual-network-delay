#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift || true

PROVIDER="vmware"
set_provider_paths "${PROVIDER}"

VMWARE_VM_ROOT="${VMWARE_VM_ROOT:-${STATE_DIR}/vms}"
VMWARE_VMRUN_TYPE="${VMWARE_VMRUN_TYPE:-fusion}"
if [[ -z "${VMWARE_GUEST_OS:-}" ]]; then
  case "$(uname -m)" in
    aarch64|arm64)
      VMWARE_GUEST_OS="arm-ubuntu-64"
      ;;
    *)
      VMWARE_GUEST_OS="ubuntu-64"
      ;;
  esac
fi
VMWARE_HARDWARE_VERSION="${VMWARE_HARDWARE_VERSION:-20}"
VMWARE_PUBLIC_NETWORK="${VMWARE_PUBLIC_NETWORK:-nat}"
VMWARE_PRIVATE_NETWORK="${VMWARE_PRIVATE_NETWORK:-hostonly}"
VMWARE_ROUTER_PRIVATE_IP="${VMWARE_ROUTER_PRIVATE_IP:-172.31.201.10}"
VMWARE_BACKEND_PRIVATE_IP="${VMWARE_BACKEND_PRIVATE_IP:-172.31.201.20}"
VMWARE_PRIVATE_PREFIX="${VMWARE_PRIVATE_PREFIX:-24}"
VM_MEMORY_MB="${VM_MEMORY_MB:-1024}"
VM_VCPUS="${VM_VCPUS:-1}"
VM_DISK_SIZE="${VM_DISK_SIZE:-8G}"
DESTROY_YES="${DESTROY_YES:-false}"

usage() {
  cat <<'EOF'
Usage: vmware-lab.sh <deploy|status|destroy> [options]

Options:
  --lab-name <name>
  --vmrun-type <fusion|ws>  Default: fusion
  --dry-run
  --yes
  --help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab-name)
        LAB_NAME="${2:?missing value for --lab-name}"
        set_provider_paths "${PROVIDER}"
        VMWARE_VM_ROOT="${STATE_DIR}/vms"
        shift 2
        ;;
      --vmrun-type)
        VMWARE_VMRUN_TYPE="${2:?missing value for --vmrun-type}"
        shift 2
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

require_vmware_cmds() {
  bool_is_true "${DRY_RUN}" && return 0
  local cmd
  for cmd in vmrun qemu-img curl ssh ssh-keygen scp; do
    require_cmd "${cmd}"
  done
}

vmware_vmx_path() {
  local role="$1"
  printf '%s/%s-%s.vmwarevm/%s-%s.vmx\n' "${VMWARE_VM_ROOT}" "${LAB_NAME}" "${role}" "${LAB_NAME}" "${role}"
}

write_vmware_vmx() {
  local role="$1"
  local vm_dir="${VMWARE_VM_ROOT}/${LAB_NAME}-${role}.vmwarevm"
  local vmx_file="${vm_dir}/${LAB_NAME}-${role}.vmx"
  local disk_file="${LAB_NAME}-${role}.vmdk"
  local seed_file="seed-${role}.iso"
  local public_mac="${2:-}"
  local private_mac="${3:-}"

  mkdir -p "${vm_dir}"

  cat > "${vmx_file}" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "${VMWARE_HARDWARE_VERSION}"
displayName = "${LAB_NAME}-${role}"
guestOS = "${VMWARE_GUEST_OS}"
firmware = "efi"
memsize = "${VM_MEMORY_MB}"
numvcpus = "${VM_VCPUS}"
msg.autoAnswer = "TRUE"
tools.syncTime = "TRUE"

pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"

sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.fileName = "${disk_file}"
sata0:0.deviceType = "disk"
sata0:1.present = "TRUE"
sata0:1.fileName = "${seed_file}"
sata0:1.deviceType = "cdrom-image"

ethernet0.present = "TRUE"
ethernet0.virtualDev = "vmxnet3"
EOF

  if [[ "${role}" == "router" ]]; then
    cat >> "${vmx_file}" <<EOF
ethernet0.connectionType = "${VMWARE_PUBLIC_NETWORK}"
ethernet0.addressType = "static"
ethernet0.address = "${public_mac}"

ethernet1.present = "TRUE"
ethernet1.virtualDev = "vmxnet3"
ethernet1.connectionType = "${VMWARE_PRIVATE_NETWORK}"
ethernet1.addressType = "static"
ethernet1.address = "${private_mac}"
EOF
  else
    cat >> "${vmx_file}" <<EOF
ethernet0.connectionType = "${VMWARE_PRIVATE_NETWORK}"
ethernet0.addressType = "static"
ethernet0.address = "${private_mac}"
EOF
  fi
}

render_seed_files() {
  local role="$1"
  local seed_dir="${STATE_DIR}/seed-${role}"
  local ssh_public_key="$2"

  mkdir -p "${seed_dir}"
  if [[ "${role}" == "router" ]]; then
    write_router_user_data "${seed_dir}/user-data" "vmware" "${VMWARE_BACKEND_PRIVATE_IP}" "${BACKEND_PORT}" "${PUBLIC_PORT}" "${ssh_public_key}"
    write_metadata "${seed_dir}/meta-data" "${LAB_NAME}-vmware-router" "${LAB_NAME}-router"
    write_vmware_router_network_config "${seed_dir}/network-config" \
      "${VMWARE_ROUTER_PUBLIC_MAC}" "${VMWARE_ROUTER_PRIVATE_MAC}" \
      "${VMWARE_ROUTER_PRIVATE_IP}" "${VMWARE_PRIVATE_PREFIX}"
  else
    write_backend_user_data "${seed_dir}/user-data" "${ssh_public_key}"
    write_metadata "${seed_dir}/meta-data" "${LAB_NAME}-vmware-backend" "${LAB_NAME}-backend"
    write_vmware_backend_network_config "${seed_dir}/network-config" \
      "${VMWARE_BACKEND_PRIVATE_MAC}" "${VMWARE_BACKEND_PRIVATE_IP}" \
      "${VMWARE_PRIVATE_PREFIX}" "${VMWARE_ROUTER_PRIVATE_IP}"
  fi
}

copy_vm_artifacts() {
  local role="$1"
  local vm_dir="${VMWARE_VM_ROOT}/${LAB_NAME}-${role}.vmwarevm"

  mkdir -p "${vm_dir}"
  run_cmd cp "${STATE_DIR}/${LAB_NAME}-${role}.vmdk" "${vm_dir}/${LAB_NAME}-${role}.vmdk"
  run_cmd cp "${STATE_DIR}/seed-${role}.iso" "${vm_dir}/seed-${role}.iso"
}

vmrun_cmd() {
  run_cmd vmrun -T "${VMWARE_VMRUN_TYPE}" "$@"
}

vmware_vmx_public_mac() {
  local vmx_file="$1"

  awk -F' = ' '
    $1 == "ethernet0.address" {
      gsub(/"/, "", $2)
      print tolower($2)
      exit
    }
  ' "${vmx_file}" 2>/dev/null
}

date_to_epoch_utc() {
  local stamp="$1"
  local epoch

  if epoch="$(date -u -j -f '%Y/%m/%d %H:%M:%S' "${stamp}" +%s 2>/dev/null)"; then
    printf '%s\n' "${epoch}"
    return 0
  fi
  if epoch="$(date -u -d "${stamp//\//-}" +%s 2>/dev/null)"; then
    printf '%s\n' "${epoch}"
    return 0
  fi
  return 1
}

vmware_dhcp_lease_ip_for_mac() {
  local mac="$1"
  local min_epoch="${2:-0}"
  local lease_file
  local lease_files=()
  local ip=""
  local latest_epoch=0
  local candidate_ip start_date start_time lease_epoch

  [[ -n "${mac}" ]] || return 0
  if [[ -n "${VMWARE_DHCP_LEASE_FILES:-}" ]]; then
    IFS=':' read -r -a lease_files <<<"${VMWARE_DHCP_LEASE_FILES}"
  else
    lease_files=(
      /var/db/vmware/vmnet-dhcpd-vmnet8.leases
      /var/lib/vmware/vmnet8/dhcpd/dhcpd.leases
    )
  fi

  for lease_file in "${lease_files[@]}"; do
    [[ -r "${lease_file}" ]] || continue
    while read -r candidate_ip start_date start_time; do
      [[ -n "${candidate_ip}" && -n "${start_date}" && -n "${start_time}" ]] || continue
      lease_epoch="$(date_to_epoch_utc "${start_date} ${start_time}" || true)"
      [[ -n "${lease_epoch}" ]] || continue
      if [[ "${lease_epoch}" -ge "${min_epoch}" && "${lease_epoch}" -ge "${latest_epoch}" ]]; then
        latest_epoch="${lease_epoch}"
        ip="${candidate_ip}"
      fi
    done < <(awk -v mac="${mac}" '
      /^lease [0-9.]+ \{/ {
        lease = $2
      }
      /^[[:space:]]*starts / {
        start_date = $3
        start_time = $4
        sub(/;$/, "", start_time)
      }
      /hardware ethernet/ {
        hw = $3
        sub(/;$/, "", hw)
        if (tolower(hw) == mac && lease != "" && start_date != "" && start_time != "") {
          print lease, start_date, start_time
        }
      }
    ' "${lease_file}")
  done

  if [[ "${ip}" =~ ^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    printf '%s\n' "${ip}"
  fi
}

wait_for_vmware_ip() {
  local vmx_file="$1"
  local timeout_seconds="${2:-420}"
  local min_lease_epoch="${3:-0}"
  local started now ip public_mac

  if bool_is_true "${DRY_RUN}"; then
    record_dry_run vmrun -T "${VMWARE_VMRUN_TYPE}" getGuestIPAddress "${vmx_file}" >&2
    printf '192.0.2.10\n'
    return 0
  fi

  public_mac="$(vmware_vmx_public_mac "${vmx_file}")"
  started="$(date +%s)"
  while true; do
    ip="$(vmrun -T "${VMWARE_VMRUN_TYPE}" getGuestIPAddress "${vmx_file}" 2>/dev/null || true)"
    if [[ ! "${ip}" =~ ^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$ ]]; then
      ip="$(vmware_dhcp_lease_ip_for_mac "${public_mac}" "${min_lease_epoch}")"
    fi
    if [[ "${ip}" =~ ^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$ ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
    now="$(date +%s)"
    [[ $((now - started)) -lt "${timeout_seconds}" ]] \
      || fail "Timed out waiting for VMware Tools IP for ${vmx_file}"
    sleep 5
  done
}

deploy_lab() {
  local image_file
  local ssh_public_key
  local router_vmx
  local backend_vmx
  local router_ip
  local deploy_started_epoch

  require_vmware_cmds
  validate_port backend-port "${BACKEND_PORT}"
  validate_port public-port "${PUBLIC_PORT}"
  mkdir -p "${STATE_DIR}" "${VMWARE_VM_ROOT}"
  state_note_defaults
  ensure_ssh_key
  ssh_public_key="$(ssh_public_key_content)"

  VMWARE_ROUTER_PUBLIC_MAC="${VMWARE_ROUTER_PUBLIC_MAC:-$(mac_from_token 00:50:56 "${LAB_NAME}-vmware-router-public" 63)}"
  VMWARE_ROUTER_PRIVATE_MAC="${VMWARE_ROUTER_PRIVATE_MAC:-$(mac_from_token 00:50:56 "${LAB_NAME}-vmware-router-private" 63)}"
  VMWARE_BACKEND_PRIVATE_MAC="${VMWARE_BACKEND_PRIVATE_MAC:-$(mac_from_token 00:50:56 "${LAB_NAME}-vmware-backend-private" 63)}"

  image_file="$(download_ubuntu_image)"
  prepare_vm_disk "${image_file}" "${STATE_DIR}/${LAB_NAME}-router.vmdk" vmdk "${VM_DISK_SIZE}"
  prepare_vm_disk "${image_file}" "${STATE_DIR}/${LAB_NAME}-backend.vmdk" vmdk "${VM_DISK_SIZE}"

  render_seed_files router "${ssh_public_key}"
  render_seed_files backend "${ssh_public_key}"
  create_seed_iso "${STATE_DIR}/seed-router" "${STATE_DIR}/seed-router.iso"
  create_seed_iso "${STATE_DIR}/seed-backend" "${STATE_DIR}/seed-backend.iso"

  write_vmware_vmx router "${VMWARE_ROUTER_PUBLIC_MAC}" "${VMWARE_ROUTER_PRIVATE_MAC}"
  write_vmware_vmx backend "" "${VMWARE_BACKEND_PRIVATE_MAC}"
  copy_vm_artifacts router
  copy_vm_artifacts backend

  router_vmx="$(vmware_vmx_path router)"
  backend_vmx="$(vmware_vmx_path backend)"

  deploy_started_epoch="$(date +%s)"
  vmrun_cmd start "${router_vmx}" nogui
  vmrun_cmd start "${backend_vmx}" nogui

  router_ip="$(wait_for_vmware_ip "${router_vmx}" 420 "${deploy_started_epoch}")"

  state_set VMWARE_VMRUN_TYPE "${VMWARE_VMRUN_TYPE}"
  state_set VMWARE_ROUTER_VMX "${router_vmx}"
  state_set VMWARE_BACKEND_VMX "${backend_vmx}"
  state_set ROUTER_HOST "${router_ip}"
  state_set ROUTER_PUBLIC_URL "http://${router_ip}:${PUBLIC_PORT}/"
  state_set ROUTER_SSH_USER "${ROUTER_SSH_USER}"
  state_set BACKEND_HOST "${VMWARE_BACKEND_PRIVATE_IP}"
  state_set BACKEND_PORT "${BACKEND_PORT}"
  state_set PUBLIC_PORT "${PUBLIC_PORT}"

  wait_for_cloud_init "${router_ip}" "${ROUTER_SSH_USER}" "${SSH_PRIVATE_KEY_FILE}" 420
  ROUTER_PUBLIC_URL="http://${router_ip}:${PUBLIC_PORT}/"
  wait_for_http_url "${ROUTER_PUBLIC_URL}" 240
  log "VMware lab is ready."
  print_lab_summary "${PROVIDER}"
}

status_lab() {
  state_load
  vmrun_cmd list
  print_lab_summary "${PROVIDER}"
}

destroy_lab() {
  state_load
  bool_is_true "${DESTROY_YES}" || fail "Refusing to destroy without --yes."
  [[ -n "${VMWARE_ROUTER_VMX:-}" ]] && vmrun_cmd stop "${VMWARE_ROUTER_VMX}" hard || true
  [[ -n "${VMWARE_BACKEND_VMX:-}" ]] && vmrun_cmd stop "${VMWARE_BACKEND_VMX}" hard || true
  run_cmd rm -rf "${VMWARE_VM_ROOT}" "${STATE_DIR}"
}

main() {
  load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
  refresh_derived_defaults
  PROVIDER="vmware"
  set_provider_paths "${PROVIDER}"
  if [[ -z "${VND_INITIAL_VMWARE_VM_ROOT:-}" && "${VMWARE_VM_ROOT}" == */.generated/vmware/vms ]]; then
    VMWARE_VM_ROOT="${STATE_DIR}/vms"
  fi
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
