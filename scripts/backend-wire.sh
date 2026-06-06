#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift || true

TARGET_PROVIDER="${PROVIDER:-docker}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-${REPO_ROOT}/assets/docker/docker-compose.yml}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${LAB_NAME}}"

usage() {
  cat <<'EOF'
Usage: backend-wire.sh <render|apply> [options]

Options:
  --provider <docker|kvm|vmware|esxi>
  --lab-name <name>
  --protocol <http|https|rtsp|tcp>
  --backend-host <host>
  --backend-port <port>
  --public-port <port>
  --router-host <host>
  --ssh-key <path>
  --ssh-user <user>
  --dry-run
  --help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)
        TARGET_PROVIDER="${2:?missing value for --provider}"
        shift 2
        ;;
      --lab-name)
        LAB_NAME="${2:?missing value for --lab-name}"
        shift 2
        ;;
      --protocol)
        BACKEND_PROTOCOL="${2:?missing value for --protocol}"
        shift 2
        ;;
      --backend-host)
        BACKEND_HOST="${2:?missing value for --backend-host}"
        shift 2
        ;;
      --backend-port)
        BACKEND_PORT="${2:?missing value for --backend-port}"
        shift 2
        ;;
      --public-port)
        PUBLIC_PORT="${2:?missing value for --public-port}"
        shift 2
        ;;
      --router-host)
        ROUTER_HOST="${2:?missing value for --router-host}"
        shift 2
        ;;
      --ssh-key)
        SSH_PRIVATE_KEY_FILE="${2:?missing value for --ssh-key}"
        shift 2
        ;;
      --ssh-user)
        ROUTER_SSH_USER="${2:?missing value for --ssh-user}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
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

preparse_provider() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)
        TARGET_PROVIDER="${2:?missing value for --provider}"
        shift 2
        ;;
      --lab-name)
        LAB_NAME="${2:?missing value for --lab-name}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
}

load_target_state() {
  set_provider_paths "${TARGET_PROVIDER}"
  state_load
  DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-${REPO_ROOT}/assets/docker/docker-compose.yml}"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${LAB_NAME}}"
  if [[ "${TARGET_PROVIDER}" == "docker" && -z "${VND_INITIAL_COMPOSE_PROJECT_NAME:-}" && "${COMPOSE_PROJECT_NAME}" == "virtual-network-delay" && "${LAB_NAME}" != "virtual-network-delay" ]]; then
    COMPOSE_PROJECT_NAME="${LAB_NAME}"
  fi

  if [[ -z "${BACKEND_HOST}" ]]; then
    case "${TARGET_PROVIDER}" in
      docker)
        BACKEND_HOST="backend"
        ;;
      kvm)
        BACKEND_HOST="${KVM_BACKEND_PRIVATE_IP:-}"
        ;;
      vmware)
        BACKEND_HOST="${VMWARE_BACKEND_PRIVATE_IP:-}"
        ;;
      esxi)
        BACKEND_HOST="${ESXI_BACKEND_PRIVATE_IP:-}"
        ;;
    esac
  fi
}

apply_docker_config() {
  local temp_file
  temp_file="$(mktemp)"
  render_haproxy_config "${BACKEND_PROTOCOL}" "${BACKEND_HOST}" "${BACKEND_PORT}" "${PUBLIC_PORT}" > "${temp_file}"

  if bool_is_true "${DRY_RUN}"; then
    record_dry_run docker compose -f "${DOCKER_COMPOSE_FILE}" -p "${COMPOSE_PROJECT_NAME}" exec -T router sh -lc "install HAProxy config from stdin"
    rm -f "${temp_file}"
    return 0
  fi

  docker compose -f "${DOCKER_COMPOSE_FILE}" -p "${COMPOSE_PROJECT_NAME}" exec -T router sh -lc '
    set -e
    cat >/tmp/virtual-network-delay-haproxy.cfg
    haproxy -c -f /tmp/virtual-network-delay-haproxy.cfg
    install -m 0644 /tmp/virtual-network-delay-haproxy.cfg /etc/haproxy/haproxy.cfg
    if [ -s /run/haproxy.pid ]; then
      haproxy -f /etc/haproxy/haproxy.cfg -D -p /run/haproxy.pid -sf $(cat /run/haproxy.pid)
    else
      haproxy -f /etc/haproxy/haproxy.cfg -D -p /run/haproxy.pid
    fi
  ' < "${temp_file}"
  rm -f "${temp_file}"
}

apply_vm_config() {
  local temp_file
  temp_file="$(mktemp)"
  render_haproxy_config "${BACKEND_PROTOCOL}" "${BACKEND_HOST}" "${BACKEND_PORT}" "${PUBLIC_PORT}" > "${temp_file}"
  scp_to_router "${temp_file}" "/tmp/virtual-network-delay-haproxy.cfg"
  ssh_run "${ROUTER_HOST}" "${ROUTER_SSH_USER}" "${SSH_PRIVATE_KEY_FILE}" \
    "sudo haproxy -c -f /tmp/virtual-network-delay-haproxy.cfg && sudo install -m 0644 /tmp/virtual-network-delay-haproxy.cfg /etc/haproxy/haproxy.cfg && sudo systemctl restart haproxy"
  rm -f "${temp_file}"
}

record_backend_state() {
  bool_is_true "${DRY_RUN}" && return 0
  state_set BACKEND_PROTOCOL "${BACKEND_PROTOCOL}"
  state_set BACKEND_HOST "${BACKEND_HOST}"
  state_set BACKEND_PORT "${BACKEND_PORT}"
  state_set PUBLIC_PORT "${PUBLIC_PORT}"
}

main() {
  load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
  refresh_derived_defaults
  TARGET_PROVIDER="${PROVIDER:-${TARGET_PROVIDER}}"
  [[ -n "${ACTION}" ]] || fail "Missing action. Use render or apply."
  preparse_provider "$@"
  load_target_state
  parse_args "$@"

  [[ -n "${BACKEND_HOST}" ]] || fail "Missing backend host."
  validate_port backend-port "${BACKEND_PORT}"
  validate_port public-port "${PUBLIC_PORT}"

  case "${ACTION}" in
    render)
      render_haproxy_config "${BACKEND_PROTOCOL}" "${BACKEND_HOST}" "${BACKEND_PORT}" "${PUBLIC_PORT}"
      ;;
    apply)
      case "${TARGET_PROVIDER}" in
        docker)
          apply_docker_config
          record_backend_state
          ;;
        kvm|vmware|esxi)
          [[ -n "${ROUTER_HOST}" ]] || fail "Missing router host. Deploy the lab or pass --router-host."
          apply_vm_config
          record_backend_state
          ;;
        *)
          fail "Unknown provider: ${TARGET_PROVIDER}"
          ;;
      esac
      ;;
    *)
      fail "Unknown action: ${ACTION}"
      ;;
  esac
}

main "$@"
