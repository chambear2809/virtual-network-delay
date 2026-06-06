#!/usr/bin/env bash
# shellcheck shell=bash

if [[ -n "${VIRTUAL_NETWORK_DELAY_COMMON_SOURCED:-}" ]]; then
  return 0
fi
VIRTUAL_NETWORK_DELAY_COMMON_SOURCED=1

COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_SCRIPT_DIR}/.." && pwd)"

VND_INITIAL_ENV_VARS="
LAB_NAME PROVIDER UBUNTU_RELEASE UBUNTU_VERSION UBUNTU_IMAGE_URL DOCKER_UBUNTU_IMAGE
STATE_ROOT STATE_DIR STATE_FILE IMAGE_DIR DRY_RUN DRY_RUN_LOG
SSH_PRIVATE_KEY_FILE SSH_PUBLIC_KEY_FILE ROUTER_SSH_USER ROUTER_HOST ROUTER_PUBLIC_URL ROUTER_DELAY_INTERFACE
BACKEND_PROTOCOL BACKEND_HOST BACKEND_PORT PUBLIC_PORT DELAY_MS JITTER_MS LOSS_PCT
CONNECT_TIMEOUT CLIENT_TIMEOUT SERVER_TIMEOUT
DOCKER_COMPOSE_FILE COMPOSE_PROJECT_NAME DOCKER_PUBLIC_BIND DOCKER_PUBLIC_PORT
KVM_PUBLIC_NETWORK KVM_PRIVATE_NETWORK KVM_PUBLIC_NETWORK_ADDRESS KVM_PUBLIC_GATEWAY KVM_PUBLIC_NETMASK
KVM_ROUTER_PUBLIC_IP KVM_PRIVATE_NETWORK_ADDRESS KVM_PRIVATE_GATEWAY KVM_PRIVATE_NETMASK
KVM_ROUTER_PRIVATE_IP KVM_BACKEND_PRIVATE_IP KVM_ROUTER_PUBLIC_MAC KVM_ROUTER_PRIVATE_MAC KVM_BACKEND_PRIVATE_MAC
VMWARE_VM_ROOT VMWARE_VMRUN_TYPE VMWARE_GUEST_OS VMWARE_HARDWARE_VERSION VMWARE_PUBLIC_NETWORK VMWARE_PRIVATE_NETWORK
VMWARE_ROUTER_PRIVATE_IP VMWARE_BACKEND_PRIVATE_IP VMWARE_PRIVATE_PREFIX
VMWARE_ROUTER_PUBLIC_MAC VMWARE_ROUTER_PRIVATE_MAC VMWARE_BACKEND_PRIVATE_MAC
VM_MEMORY_MB VM_VCPUS VM_DISK_SIZE
"

for VND_INITIAL_ENV_VAR in ${VND_INITIAL_ENV_VARS}; do
  if [[ -n "${!VND_INITIAL_ENV_VAR+x}" ]]; then
    eval "VND_INITIAL_${VND_INITIAL_ENV_VAR}=1"
  fi
done
unset VND_INITIAL_ENV_VAR

LAB_NAME="${LAB_NAME:-virtual-network-delay}"
PROVIDER="${PROVIDER:-docker}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
DOCKER_UBUNTU_IMAGE="${DOCKER_UBUNTU_IMAGE:-ubuntu:24.04}"

STATE_ROOT="${STATE_ROOT:-${REPO_ROOT}/.generated}"
STATE_DIR="${STATE_DIR:-${STATE_ROOT}/${PROVIDER}}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/${LAB_NAME}.env}"
IMAGE_DIR="${IMAGE_DIR:-${STATE_ROOT}/images}"
DRY_RUN="${DRY_RUN:-false}"
DRY_RUN_LOG="${DRY_RUN_LOG:-}"

SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
ROUTER_SSH_USER="${ROUTER_SSH_USER:-ubuntu}"
ROUTER_HOST="${ROUTER_HOST:-}"
ROUTER_PUBLIC_URL="${ROUTER_PUBLIC_URL:-}"
ROUTER_DELAY_INTERFACE="${ROUTER_DELAY_INTERFACE:-}"

BACKEND_PROTOCOL="${BACKEND_PROTOCOL:-http}"
BACKEND_HOST="${BACKEND_HOST:-}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
PUBLIC_PORT="${PUBLIC_PORT:-80}"
DELAY_MS="${DELAY_MS:-150}"
JITTER_MS="${JITTER_MS:-0}"
LOSS_PCT="${LOSS_PCT:-0}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5s}"
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-60s}"
SERVER_TIMEOUT="${SERVER_TIMEOUT:-60s}"

log() {
  printf '[virtual-network-delay] %s\n' "$*"
}

warn() {
  printf '[virtual-network-delay] WARN: %s\n' "$*" >&2
}

fail() {
  printf '[virtual-network-delay] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local name="$1"
  command -v "${name}" >/dev/null 2>&1 || fail "Missing required command: ${name}"
}

bool_is_true() {
  [[ "$1" == "true" || "$1" == "1" || "$1" == "yes" ]]
}

set_provider_paths() {
  PROVIDER="$1"
  STATE_DIR="${STATE_ROOT}/${PROVIDER}"
  STATE_FILE="${STATE_DIR}/${LAB_NAME}.env"
}

refresh_derived_defaults() {
  if [[ -z "${VND_INITIAL_IMAGE_DIR:-}" ]]; then
    IMAGE_DIR="${STATE_ROOT}/images"
  fi
}

load_env_file() {
  local env_file="$1"
  local line key value explicit_key

  [[ -f "${env_file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == export\ * ]] && line="${line#export }"
    [[ "${line}" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    [[ "${key}" == [A-Za-z_][A-Za-z0-9_]* ]] || continue
    explicit_key="VND_INITIAL_${key}"
    [[ -z "${!explicit_key:-}" ]] || continue

    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi

    export "${key}=${value}"
  done < "${env_file}"
}

state_load() {
  [[ -f "${STATE_FILE}" ]] || return 0
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
}

state_set() {
  local key="$1"
  local value="$2"
  local tmp

  mkdir -p "$(dirname "${STATE_FILE}")"
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"

  if [[ -f "${STATE_FILE}" ]]; then
    grep -v -E "^${key}=" "${STATE_FILE}" > "${tmp}" || true
  fi

  printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
  mv "${tmp}" "${STATE_FILE}"
}

state_note_defaults() {
  mkdir -p "${STATE_DIR}"
  state_set LAB_NAME "${LAB_NAME}"
  state_set PROVIDER "${PROVIDER}"
  state_set UBUNTU_RELEASE "${UBUNTU_RELEASE}"
  state_set UBUNTU_VERSION "${UBUNTU_VERSION}"
}

record_dry_run() {
  local rendered=""
  local arg

  for arg in "$@"; do
    printf -v rendered '%s %q' "${rendered}" "${arg}"
  done
  rendered="${rendered# }"
  printf '[dry-run] %s\n' "${rendered}"
  if [[ -n "${DRY_RUN_LOG}" ]]; then
    printf '%s\n' "${rendered}" >> "${DRY_RUN_LOG}"
  fi
}

run_cmd() {
  if bool_is_true "${DRY_RUN}"; then
    record_dry_run "$@"
    return 0
  fi

  "$@"
}

render_shell_command() {
  local rendered=""
  local arg

  for arg in "$@"; do
    printf -v rendered '%s %q' "${rendered}" "${arg}"
  done
  printf '%s' "${rendered# }"
}

validate_number() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "${name} must be numeric, got: ${value}"
}

validate_port() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1 && "${value}" -le 65535 ]] \
    || fail "${name} must be a TCP port, got: ${value}"
}

ubuntu_cloud_arch() {
  local machine
  machine="$(uname -m)"

  case "${machine}" in
    x86_64|amd64)
      printf 'amd64\n'
      ;;
    aarch64|arm64)
      printf 'arm64\n'
      ;;
    *)
      fail "Unsupported host architecture for Ubuntu cloud image: ${machine}"
      ;;
  esac
}

ubuntu_image_url() {
  local arch
  arch="$(ubuntu_cloud_arch)"

  if [[ -n "${UBUNTU_IMAGE_URL:-}" ]]; then
    printf '%s\n' "${UBUNTU_IMAGE_URL}"
  else
    printf 'https://cloud-images.ubuntu.com/%s/current/%s-server-cloudimg-%s.img\n' \
      "${UBUNTU_RELEASE}" "${UBUNTU_RELEASE}" "${arch}"
  fi
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    fail "Need sha256sum or shasum to verify Ubuntu image checksums."
  fi
}

download_ubuntu_image() {
  local url
  local image_name
  local image_file
  local checksum_url
  local checksum_file
  local expected
  local actual

  url="$(ubuntu_image_url)"
  image_name="${url##*/}"
  image_file="${IMAGE_DIR}/${image_name}"

  mkdir -p "${IMAGE_DIR}"
  if [[ -f "${image_file}" ]]; then
    log "Reusing Ubuntu cloud image ${image_file}" >&2
    printf '%s\n' "${image_file}"
    return 0
  fi

  if bool_is_true "${DRY_RUN}"; then
    record_dry_run curl -fL "${url}" -o "${image_file}" >&2
    printf '%s\n' "${image_file}"
    return 0
  fi

  require_cmd curl
  log "Downloading Ubuntu cloud image ${url}" >&2
  curl -fL "${url}" -o "${image_file}.tmp"

  if [[ -z "${UBUNTU_IMAGE_URL:-}" ]]; then
    checksum_url="${url%/*}/SHA256SUMS"
    checksum_file="${IMAGE_DIR}/${UBUNTU_RELEASE}-SHA256SUMS"
    curl -fsSL "${checksum_url}" -o "${checksum_file}"
    expected="$(awk -v f="${image_name}" '$2 == f || $2 == "*" f { print $1; exit }' "${checksum_file}")"
    if [[ -n "${expected}" ]]; then
      actual="$(sha256_file "${image_file}.tmp")"
      [[ "${actual}" == "${expected}" ]] \
        || fail "Checksum mismatch for ${image_name}: expected ${expected}, got ${actual}"
    else
      warn "No checksum entry found for ${image_name}; continuing without checksum validation."
    fi
  else
    warn "Custom UBUNTU_IMAGE_URL set; checksum validation skipped."
  fi

  mv "${image_file}.tmp" "${image_file}"
  printf '%s\n' "${image_file}"
}

ensure_ssh_key() {
  SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-${STATE_DIR}/${LAB_NAME}.id_ed25519}"
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-${SSH_PRIVATE_KEY_FILE}.pub}"

  mkdir -p "${STATE_DIR}"
  if bool_is_true "${DRY_RUN}" && [[ ! -f "${SSH_PRIVATE_KEY_FILE}" ]]; then
    printf 'dry-run-private-key\n' > "${SSH_PRIVATE_KEY_FILE}"
    chmod 600 "${SSH_PRIVATE_KEY_FILE}" 2>/dev/null || true
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunVirtualNetworkDelayKey %s-dry-run\n' "${LAB_NAME}" > "${SSH_PUBLIC_KEY_FILE}"
    state_set SSH_PRIVATE_KEY_FILE "${SSH_PRIVATE_KEY_FILE}"
    state_set SSH_PUBLIC_KEY_FILE "${SSH_PUBLIC_KEY_FILE}"
    return 0
  fi

  if [[ ! -f "${SSH_PRIVATE_KEY_FILE}" ]]; then
    run_cmd ssh-keygen -t ed25519 -f "${SSH_PRIVATE_KEY_FILE}" -N "" -C "${LAB_NAME}"
    run_cmd chmod 600 "${SSH_PRIVATE_KEY_FILE}"
  fi

  if [[ ! -f "${SSH_PUBLIC_KEY_FILE}" && -f "${SSH_PRIVATE_KEY_FILE}" ]]; then
    ssh-keygen -y -f "${SSH_PRIVATE_KEY_FILE}" > "${SSH_PUBLIC_KEY_FILE}"
  fi

  state_set SSH_PRIVATE_KEY_FILE "${SSH_PRIVATE_KEY_FILE}"
  state_set SSH_PUBLIC_KEY_FILE "${SSH_PUBLIC_KEY_FILE}"
}

ssh_public_key_content() {
  [[ -f "${SSH_PUBLIC_KEY_FILE}" ]] || fail "Missing SSH public key file: ${SSH_PUBLIC_KEY_FILE}"
  sed -n '1p' "${SSH_PUBLIC_KEY_FILE}"
}

mac_from_token() {
  local prefix="$1"
  local token="$2"
  local max_first="${3:-255}"
  local checksum b1 b2 b3

  checksum="$(printf '%s' "${token}" | cksum | awk '{print $1}')"
  b1=$((checksum % (max_first + 1)))
  b2=$(((checksum / 257) % 256))
  b3=$(((checksum / 65537) % 256))
  printf '%s:%02x:%02x:%02x\n' "${prefix}" "${b1}" "${b2}" "${b3}"
}

haproxy_mode_for_protocol() {
  case "$1" in
    http)
      printf 'http\n'
      ;;
    https|rtsp|tcp)
      printf 'tcp\n'
      ;;
    *)
      fail "Unsupported protocol: $1"
      ;;
  esac
}

render_haproxy_config() {
  local protocol="$1"
  local backend_host="$2"
  local backend_port="$3"
  local public_port="$4"
  local mode

  mode="$(haproxy_mode_for_protocol "${protocol}")"

  cat <<EOF
global
  log stdout format raw local0
  maxconn 4096
  stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners

defaults
  log global
  mode ${mode}
  option dontlognull
  timeout connect ${CONNECT_TIMEOUT}
  timeout client ${CLIENT_TIMEOUT}
  timeout server ${SERVER_TIMEOUT}

frontend public_${protocol}_${public_port}
  bind *:${public_port}
  mode ${mode}
  default_backend backend_${protocol}_${backend_port}

backend backend_${protocol}_${backend_port}
  mode ${mode}
  server target ${backend_host}:${backend_port} check
EOF
}

write_router_user_data() {
  local output_file="$1"
  local provider_name="$2"
  local backend_host="$3"
  local backend_port="$4"
  local public_port="$5"
  local ssh_public_key="$6"
  local open_vm_tools_package=""

  if [[ "${provider_name}" == "vmware" ]]; then
    open_vm_tools_package="  - open-vm-tools"
  fi

  mkdir -p "$(dirname "${output_file}")"
  cat > "${output_file}" <<EOF
#cloud-config
hostname: ${LAB_NAME}-router
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: ubuntu
    gecos: Ubuntu
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}
package_update: true
packages:
  - ca-certificates
  - curl
  - haproxy
  - iproute2
  - iptables
${open_vm_tools_package}
write_files:
  - path: /etc/haproxy/haproxy.cfg
    owner: root:root
    permissions: '0644'
    content: |
$(render_haproxy_config "${BACKEND_PROTOCOL}" "${backend_host}" "${backend_port}" "${public_port}" | sed 's/^/      /')
  - path: /usr/local/sbin/virtual-network-delay-router-bootstrap
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail

      public_if="\$(ip route show default | awk '{print \$5; exit}')"
      sysctl -w net.ipv4.ip_forward=1

      if [[ -n "\${public_if}" ]]; then
        iptables -t nat -C POSTROUTING -o "\${public_if}" -j MASQUERADE 2>/dev/null \
          || iptables -t nat -A POSTROUTING -o "\${public_if}" -j MASQUERADE
      fi

      haproxy -c -f /etc/haproxy/haproxy.cfg
      systemctl enable --now haproxy
  - path: /etc/systemd/system/virtual-network-delay-router-bootstrap.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Configure virtual network-delay router
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/virtual-network-delay-router-bootstrap
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable --now virtual-network-delay-router-bootstrap.service
EOF
}

write_backend_user_data() {
  local output_file="$1"
  local ssh_public_key="$2"

  mkdir -p "$(dirname "${output_file}")"
  cat > "${output_file}" <<EOF
#cloud-config
hostname: ${LAB_NAME}-backend
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: ubuntu
    gecos: Ubuntu
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}
write_files:
  - path: /usr/local/bin/virtual-network-delay-backend.py
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from datetime import datetime, timezone
      import socket

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              body = (
                  "virtual-network-delay backend\\n"
                  f"host={socket.gethostname()}\\n"
                  f"path={self.path}\\n"
                  f"time={datetime.now(timezone.utc).isoformat()}\\n"
              ).encode("utf-8")
              self.send_response(200)
              self.send_header("Content-Type", "text/plain; charset=utf-8")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, fmt, *args):
              return

      ThreadingHTTPServer(("0.0.0.0", ${BACKEND_PORT}), Handler).serve_forever()
  - path: /etc/systemd/system/virtual-network-delay-backend.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Virtual network-delay sample backend
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/bin/python3 /usr/local/bin/virtual-network-delay-backend.py
      Restart=always
      RestartSec=2

      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable --now virtual-network-delay-backend.service
EOF
}

write_metadata() {
  local output_file="$1"
  local instance_id="$2"
  local hostname="$3"

  mkdir -p "$(dirname "${output_file}")"
  cat > "${output_file}" <<EOF
instance-id: ${instance_id}
local-hostname: ${hostname}
EOF
}

write_kvm_router_network_config() {
  local output_file="$1"
  local public_mac="$2"
  local private_mac="$3"
  local public_ip="$4"
  local public_gateway="$5"
  local private_ip="$6"

  cat > "${output_file}" <<EOF
version: 2
ethernets:
  public0:
    match:
      macaddress: "${public_mac}"
    set-name: public0
    dhcp4: false
    addresses:
      - ${public_ip}/24
    routes:
      - to: default
        via: ${public_gateway}
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
  private0:
    match:
      macaddress: "${private_mac}"
    set-name: private0
    dhcp4: false
    addresses:
      - ${private_ip}/24
EOF
}

write_kvm_backend_network_config() {
  local output_file="$1"
  local private_mac="$2"
  local private_ip="$3"
  local router_private_ip="$4"

  cat > "${output_file}" <<EOF
version: 2
ethernets:
  private0:
    match:
      macaddress: "${private_mac}"
    set-name: private0
    dhcp4: false
    addresses:
      - ${private_ip}/24
    routes:
      - to: default
        via: ${router_private_ip}
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
EOF
}

write_vmware_router_network_config() {
  local output_file="$1"
  local public_mac="$2"
  local private_mac="$3"
  local private_ip="$4"
  local private_prefix="$5"

  cat > "${output_file}" <<EOF
version: 2
ethernets:
  public0:
    match:
      macaddress: "${public_mac}"
    set-name: public0
    dhcp4: true
  private0:
    match:
      macaddress: "${private_mac}"
    set-name: private0
    dhcp4: false
    addresses:
      - ${private_ip}/${private_prefix}
EOF
}

write_vmware_backend_network_config() {
  local output_file="$1"
  local private_mac="$2"
  local private_ip="$3"
  local private_prefix="$4"
  local router_private_ip="$5"

  cat > "${output_file}" <<EOF
version: 2
ethernets:
  private0:
    match:
      macaddress: "${private_mac}"
    set-name: private0
    dhcp4: false
    addresses:
      - ${private_ip}/${private_prefix}
    routes:
      - to: default
        via: ${router_private_ip}
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
EOF
}

create_seed_iso() {
  local seed_dir="$1"
  local iso_file="$2"
  local user_data="${seed_dir}/user-data"
  local meta_data="${seed_dir}/meta-data"
  local network_config="${seed_dir}/network-config"

  [[ -f "${user_data}" && -f "${meta_data}" && -f "${network_config}" ]] \
    || fail "Seed source missing user-data, meta-data, or network-config under ${seed_dir}"

  mkdir -p "$(dirname "${iso_file}")"
  rm -f "${iso_file}"

  if bool_is_true "${DRY_RUN}"; then
    record_dry_run cloud-localds "--network-config=${network_config}" "${iso_file}" "${user_data}" "${meta_data}"
    return 0
  fi

  if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "--network-config=${network_config}" "${iso_file}" "${user_data}" "${meta_data}"
  elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "${iso_file}" -volid cidata -joliet -rock \
      "${user_data}" "${meta_data}" "${network_config}"
  elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -quiet -output "${iso_file}" -volid cidata -joliet -rock \
      "${user_data}" "${meta_data}" "${network_config}"
  elif command -v hdiutil >/dev/null 2>&1; then
    hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata \
      -o "${iso_file}" "${seed_dir}"
  else
    fail "Need cloud-localds, genisoimage, mkisofs, or hdiutil to create NoCloud seed ISO."
  fi
}

prepare_vm_disk() {
  local source_image="$1"
  local output_disk="$2"
  local output_format="$3"
  local disk_size="$4"

  mkdir -p "$(dirname "${output_disk}")"
  if [[ -f "${output_disk}" ]]; then
    log "Reusing disk ${output_disk}"
    return 0
  fi

  if [[ "${output_format}" == "vmdk" ]]; then
    run_cmd qemu-img convert -O vmdk -o subformat=monolithicSparse "${source_image}" "${output_disk}"
  else
    run_cmd qemu-img convert -O "${output_format}" "${source_image}" "${output_disk}"
  fi

  run_cmd qemu-img resize "${output_disk}" "${disk_size}"
}

ssh_run() {
  local host="$1"
  local user="$2"
  local key_file="$3"
  local remote_command="$4"
  local ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)

  [[ -n "${host}" ]] || fail "Missing SSH host."
  if [[ -n "${key_file}" ]]; then
    ssh_opts+=(-i "${key_file}")
  fi

  if bool_is_true "${DRY_RUN}"; then
    record_dry_run ssh "${ssh_opts[@]}" "${user}@${host}" "${remote_command}"
  else
    # remote_command is intentionally composed locally from validated script inputs.
    # shellcheck disable=SC2029
    ssh "${ssh_opts[@]}" "${user}@${host}" "${remote_command}"
  fi
}

scp_to_router() {
  local local_file="$1"
  local remote_path="$2"
  local ssh_opts=(-o StrictHostKeyChecking=accept-new)

  [[ -n "${ROUTER_HOST}" ]] || fail "Missing router host."
  if [[ -n "${SSH_PRIVATE_KEY_FILE}" ]]; then
    ssh_opts+=(-i "${SSH_PRIVATE_KEY_FILE}")
  fi

  if bool_is_true "${DRY_RUN}"; then
    record_dry_run scp "${ssh_opts[@]}" "${local_file}" "${ROUTER_SSH_USER}@${ROUTER_HOST}:${remote_path}"
  else
    scp "${ssh_opts[@]}" "${local_file}" "${ROUTER_SSH_USER}@${ROUTER_HOST}:${remote_path}"
  fi
}

wait_for_ssh() {
  local host="$1"
  local user="$2"
  local key_file="$3"
  local timeout_seconds="${4:-240}"
  local started now

  bool_is_true "${DRY_RUN}" && return 0
  started="$(date +%s)"
  while true; do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      -i "${key_file}" "${user}@${host}" "true" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    [[ $((now - started)) -lt "${timeout_seconds}" ]] \
      || fail "Timed out waiting for SSH on ${user}@${host}"
    sleep 5
  done
}

wait_for_cloud_init() {
  local host="$1"
  local user="$2"
  local key_file="$3"
  local timeout_seconds="${4:-420}"

  bool_is_true "${DRY_RUN}" && return 0
  wait_for_ssh "${host}" "${user}" "${key_file}" "${timeout_seconds}"
  ssh_run "${host}" "${user}" "${key_file}" "sudo cloud-init status --wait"
}

wait_for_http_url() {
  local url="$1"
  local timeout_seconds="${2:-180}"
  local started now status

  [[ -n "${url}" ]] || return 0
  bool_is_true "${DRY_RUN}" && return 0
  require_cmd curl

  log "Waiting for ${url}"
  started="$(date +%s)"
  while true; do
    status="$(curl -o /dev/null -sS -w '%{http_code}' "${url}" 2>/dev/null || true)"
    if [[ "${status}" =~ ^[23][0-9][0-9]$ ]]; then
      return 0
    fi
    now="$(date +%s)"
    [[ $((now - started)) -lt "${timeout_seconds}" ]] \
      || fail "Timed out waiting for ${url} to return HTTP 2xx/3xx."
    sleep 3
  done
}

print_lab_summary() {
  local provider="$1"
  local url="${ROUTER_PUBLIC_URL:-}"
  local lab_option=""

  [[ -n "${url}" ]] || return 0
  if [[ "${LAB_NAME}" != "virtual-network-delay" ]]; then
    printf -v lab_option ' --lab-name %q' "${LAB_NAME}"
  fi
  printf 'provider=%s\n' "${provider}"
  printf 'lab_name=%s\n' "${LAB_NAME}"
  printf 'router_url=%s\n' "${url}"
  printf 'status_command=bash scripts/router-delay.sh status --provider %s%s\n' "${provider}" "${lab_option}"
  printf 'enable_delay_command=bash scripts/router-delay.sh enable --provider %s%s --delay-ms %s --jitter-ms %s --loss-pct %s\n' \
    "${provider}" "${lab_option}" "${DELAY_MS}" "${JITTER_MS}" "${LOSS_PCT}"
  printf 'disable_delay_command=bash scripts/router-delay.sh disable --provider %s%s\n' "${provider}" "${lab_option}"
  printf 'validate_command=bash scripts/validate-router-delay.sh validate --provider %s%s --delay-ms %s\n' \
    "${provider}" "${lab_option}" "${DELAY_MS}"
}

provider_is_vm() {
  [[ "$1" == "kvm" || "$1" == "vmware" ]]
}
