#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift || true

PROVIDER="kvm"
set_provider_paths "${PROVIDER}"

KVM_PUBLIC_NETWORK="${KVM_PUBLIC_NETWORK:-${LAB_NAME}-public}"
KVM_PRIVATE_NETWORK="${KVM_PRIVATE_NETWORK:-${LAB_NAME}-private}"
KVM_PUBLIC_NETWORK_ADDRESS="${KVM_PUBLIC_NETWORK_ADDRESS:-192.168.110.0}"
KVM_PUBLIC_GATEWAY="${KVM_PUBLIC_GATEWAY:-192.168.110.1}"
KVM_PUBLIC_NETMASK="${KVM_PUBLIC_NETMASK:-255.255.255.0}"
KVM_ROUTER_PUBLIC_IP="${KVM_ROUTER_PUBLIC_IP:-192.168.110.10}"
KVM_PRIVATE_NETWORK_ADDRESS="${KVM_PRIVATE_NETWORK_ADDRESS:-192.168.111.0}"
KVM_PRIVATE_GATEWAY="${KVM_PRIVATE_GATEWAY:-192.168.111.1}"
KVM_PRIVATE_NETMASK="${KVM_PRIVATE_NETMASK:-255.255.255.0}"
KVM_ROUTER_PRIVATE_IP="${KVM_ROUTER_PRIVATE_IP:-192.168.111.10}"
KVM_BACKEND_PRIVATE_IP="${KVM_BACKEND_PRIVATE_IP:-192.168.111.20}"
VM_MEMORY_MB="${VM_MEMORY_MB:-1024}"
VM_VCPUS="${VM_VCPUS:-1}"
VM_DISK_SIZE="${VM_DISK_SIZE:-8G}"
DESTROY_YES="${DESTROY_YES:-false}"

usage() {
  cat <<'EOF'
Usage: kvm-lab.sh <deploy|status|destroy> [options]

Options:
  --lab-name <name>
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
        KVM_PUBLIC_NETWORK="${LAB_NAME}-public"
        KVM_PRIVATE_NETWORK="${LAB_NAME}-private"
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

require_kvm_cmds() {
  bool_is_true "${DRY_RUN}" && return 0
  local cmd
  for cmd in virsh virt-install qemu-img curl ssh ssh-keygen scp; do
    require_cmd "${cmd}"
  done
}

create_libvirt_network() {
  local name="$1"
  local mode="$2"
  local address="$3"
  local netmask="$4"
  local xml_file="${STATE_DIR}/${name}.xml"
  local bridge_name

  bridge_name="$(printf 'vnd%s' "$(printf '%s' "${name}" | cksum | awk '{printf "%08x", $1}')" | cut -c1-15)"

  mkdir -p "${STATE_DIR}"
  if [[ "${mode}" == "nat" ]]; then
    cat > "${xml_file}" <<EOF
<network>
  <name>${name}</name>
  <bridge name='${bridge_name}' stp='on' delay='0'/>
  <forward mode='nat'/>
  <ip address='${address}' netmask='${netmask}'/>
</network>
EOF
  else
    cat > "${xml_file}" <<EOF
<network>
  <name>${name}</name>
  <bridge name='${bridge_name}' stp='on' delay='0'/>
  <ip address='${address}' netmask='${netmask}'/>
</network>
EOF
  fi

  if ! bool_is_true "${DRY_RUN}" && virsh net-info "${name}" >/dev/null 2>&1; then
    log "Reusing libvirt network ${name}"
    return 0
  fi

  run_cmd virsh net-define "${xml_file}"
  run_cmd virsh net-start "${name}"
  run_cmd virsh net-autostart "${name}"
}

render_seed_files() {
  local role="$1"
  local seed_dir="${STATE_DIR}/seed-${role}"
  local ssh_public_key="$2"

  mkdir -p "${seed_dir}"
  if [[ "${role}" == "router" ]]; then
    write_router_user_data "${seed_dir}/user-data" "kvm" "${KVM_BACKEND_PRIVATE_IP}" "${BACKEND_PORT}" "${PUBLIC_PORT}" "${ssh_public_key}"
    write_metadata "${seed_dir}/meta-data" "${LAB_NAME}-kvm-router" "${LAB_NAME}-router"
    write_kvm_router_network_config "${seed_dir}/network-config" \
      "${KVM_ROUTER_PUBLIC_MAC}" "${KVM_ROUTER_PRIVATE_MAC}" \
      "${KVM_ROUTER_PUBLIC_IP}" "${KVM_PUBLIC_GATEWAY}" "${KVM_ROUTER_PRIVATE_IP}"
  else
    write_backend_user_data "${seed_dir}/user-data" "${ssh_public_key}"
    write_metadata "${seed_dir}/meta-data" "${LAB_NAME}-kvm-backend" "${LAB_NAME}-backend"
    write_kvm_backend_network_config "${seed_dir}/network-config" \
      "${KVM_BACKEND_PRIVATE_MAC}" "${KVM_BACKEND_PRIVATE_IP}" "${KVM_ROUTER_PRIVATE_IP}"
  fi
}

virt_install_router() {
  run_cmd virt-install \
    --name "${LAB_NAME}-router" \
    --import \
    --memory "${VM_MEMORY_MB}" \
    --vcpus "${VM_VCPUS}" \
    --osinfo generic \
    --disk "path=${STATE_DIR}/${LAB_NAME}-router.qcow2,bus=virtio,format=qcow2" \
    --disk "path=${STATE_DIR}/seed-router.iso,device=cdrom" \
    --network "network=${KVM_PUBLIC_NETWORK},model=virtio,mac=${KVM_ROUTER_PUBLIC_MAC}" \
    --network "network=${KVM_PRIVATE_NETWORK},model=virtio,mac=${KVM_ROUTER_PRIVATE_MAC}" \
    --graphics none \
    --noautoconsole
}

virt_install_backend() {
  run_cmd virt-install \
    --name "${LAB_NAME}-backend" \
    --import \
    --memory "${VM_MEMORY_MB}" \
    --vcpus "${VM_VCPUS}" \
    --osinfo generic \
    --disk "path=${STATE_DIR}/${LAB_NAME}-backend.qcow2,bus=virtio,format=qcow2" \
    --disk "path=${STATE_DIR}/seed-backend.iso,device=cdrom" \
    --network "network=${KVM_PRIVATE_NETWORK},model=virtio,mac=${KVM_BACKEND_PRIVATE_MAC}" \
    --graphics none \
    --noautoconsole
}

grant_libvirt_storage_access() {
  local libvirt_user="libvirt-qemu"
  local path
  local storage_file

  bool_is_true "${DRY_RUN}" && return 0
  id -u "${libvirt_user}" >/dev/null 2>&1 || return 0
  require_cmd setfacl

  path="${STATE_DIR}"
  while [[ "${path}" != "/" && -n "${path}" ]]; do
    run_cmd setfacl -m "u:${libvirt_user}:x" "${path}"
    path="$(dirname "${path}")"
  done

  for storage_file in \
    "${STATE_DIR}/${LAB_NAME}-router.qcow2" \
    "${STATE_DIR}/${LAB_NAME}-backend.qcow2"; do
    [[ -f "${storage_file}" ]] && run_cmd setfacl -m "u:${libvirt_user}:rw" "${storage_file}"
  done

  for storage_file in \
    "${STATE_DIR}/seed-router.iso" \
    "${STATE_DIR}/seed-backend.iso"; do
    [[ -f "${storage_file}" ]] && run_cmd setfacl -m "u:${libvirt_user}:r" "${storage_file}"
  done
}

deploy_lab() {
  local image_file
  local ssh_public_key

  require_kvm_cmds
  validate_port backend-port "${BACKEND_PORT}"
  validate_port public-port "${PUBLIC_PORT}"
  mkdir -p "${STATE_DIR}"
  state_note_defaults
  ensure_ssh_key
  ssh_public_key="$(ssh_public_key_content)"

  KVM_ROUTER_PUBLIC_MAC="${KVM_ROUTER_PUBLIC_MAC:-$(mac_from_token 52:54:00 "${LAB_NAME}-kvm-router-public")}"
  KVM_ROUTER_PRIVATE_MAC="${KVM_ROUTER_PRIVATE_MAC:-$(mac_from_token 52:54:00 "${LAB_NAME}-kvm-router-private")}"
  KVM_BACKEND_PRIVATE_MAC="${KVM_BACKEND_PRIVATE_MAC:-$(mac_from_token 52:54:00 "${LAB_NAME}-kvm-backend-private")}"

  create_libvirt_network "${KVM_PUBLIC_NETWORK}" nat "${KVM_PUBLIC_GATEWAY}" "${KVM_PUBLIC_NETMASK}"
  create_libvirt_network "${KVM_PRIVATE_NETWORK}" isolated "${KVM_PRIVATE_GATEWAY}" "${KVM_PRIVATE_NETMASK}"

  image_file="$(download_ubuntu_image)"
  prepare_vm_disk "${image_file}" "${STATE_DIR}/${LAB_NAME}-router.qcow2" qcow2 "${VM_DISK_SIZE}"
  prepare_vm_disk "${image_file}" "${STATE_DIR}/${LAB_NAME}-backend.qcow2" qcow2 "${VM_DISK_SIZE}"

  render_seed_files router "${ssh_public_key}"
  render_seed_files backend "${ssh_public_key}"
  create_seed_iso "${STATE_DIR}/seed-router" "${STATE_DIR}/seed-router.iso"
  create_seed_iso "${STATE_DIR}/seed-backend" "${STATE_DIR}/seed-backend.iso"
  grant_libvirt_storage_access

  virt_install_router
  virt_install_backend

  state_set KVM_PUBLIC_NETWORK "${KVM_PUBLIC_NETWORK}"
  state_set KVM_PRIVATE_NETWORK "${KVM_PRIVATE_NETWORK}"
  state_set ROUTER_HOST "${KVM_ROUTER_PUBLIC_IP}"
  state_set ROUTER_PUBLIC_URL "http://${KVM_ROUTER_PUBLIC_IP}:${PUBLIC_PORT}/"
  state_set ROUTER_SSH_USER "${ROUTER_SSH_USER}"
  state_set BACKEND_HOST "${KVM_BACKEND_PRIVATE_IP}"
  state_set BACKEND_PORT "${BACKEND_PORT}"
  state_set PUBLIC_PORT "${PUBLIC_PORT}"

  wait_for_cloud_init "${KVM_ROUTER_PUBLIC_IP}" "${ROUTER_SSH_USER}" "${SSH_PRIVATE_KEY_FILE}" 420
  ROUTER_PUBLIC_URL="http://${KVM_ROUTER_PUBLIC_IP}:${PUBLIC_PORT}/"
  wait_for_http_url "${ROUTER_PUBLIC_URL}" 240
  log "KVM lab is ready."
  print_lab_summary "${PROVIDER}"
}

status_lab() {
  state_load
  run_cmd virsh domstate "${LAB_NAME}-router"
  run_cmd virsh domstate "${LAB_NAME}-backend"
  ROUTER_PUBLIC_URL="${ROUTER_PUBLIC_URL:-http://${KVM_ROUTER_PUBLIC_IP}:${PUBLIC_PORT}/}"
  print_lab_summary "${PROVIDER}"
}

destroy_lab() {
  state_load
  bool_is_true "${DESTROY_YES}" || fail "Refusing to destroy without --yes."
  run_cmd virsh destroy "${LAB_NAME}-router" || true
  run_cmd virsh destroy "${LAB_NAME}-backend" || true
  run_cmd virsh undefine "${LAB_NAME}-router" --remove-all-storage || true
  run_cmd virsh undefine "${LAB_NAME}-backend" --remove-all-storage || true
  run_cmd virsh net-destroy "${KVM_PUBLIC_NETWORK:-${LAB_NAME}-public}" || true
  run_cmd virsh net-destroy "${KVM_PRIVATE_NETWORK:-${LAB_NAME}-private}" || true
  run_cmd virsh net-undefine "${KVM_PUBLIC_NETWORK:-${LAB_NAME}-public}" || true
  run_cmd virsh net-undefine "${KVM_PRIVATE_NETWORK:-${LAB_NAME}-private}" || true
  run_cmd rm -rf "${STATE_DIR}"
}

main() {
  load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
  refresh_derived_defaults
  PROVIDER="kvm"
  set_provider_paths "${PROVIDER}"
  if [[ -z "${VND_INITIAL_KVM_PUBLIC_NETWORK:-}" && "${KVM_PUBLIC_NETWORK}" == "virtual-network-delay-public" && "${LAB_NAME}" != "virtual-network-delay" ]]; then
    KVM_PUBLIC_NETWORK="${LAB_NAME}-public"
  fi
  if [[ -z "${VND_INITIAL_KVM_PRIVATE_NETWORK:-}" && "${KVM_PRIVATE_NETWORK}" == "virtual-network-delay-private" && "${LAB_NAME}" != "virtual-network-delay" ]]; then
    KVM_PRIVATE_NETWORK="${LAB_NAME}-private"
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
