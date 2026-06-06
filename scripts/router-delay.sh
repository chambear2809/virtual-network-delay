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
Usage: router-delay.sh <status|enable|disable> [options]

Options:
  --provider <docker|kvm|vmware>
  --lab-name <name>
  --delay-ms <ms>
  --jitter-ms <ms>
  --loss-pct <percent>
  --interface <name>
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
      --delay-ms)
        DELAY_MS="${2:?missing value for --delay-ms}"
        shift 2
        ;;
      --jitter-ms)
        JITTER_MS="${2:?missing value for --jitter-ms}"
        shift 2
        ;;
      --loss-pct)
        LOSS_PCT="${2:?missing value for --loss-pct}"
        shift 2
        ;;
      --interface)
        ROUTER_DELAY_INTERFACE="${2:?missing value for --interface}"
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

remote_interface_assignment() {
  if [[ -n "${ROUTER_DELAY_INTERFACE}" ]]; then
    printf 'iface=%q' "${ROUTER_DELAY_INTERFACE}"
  else
    printf "iface=\"\$(ip route show default | awk '{print \$5; exit}')\""
  fi
}

netem_command_args() {
  local args=(netem delay "${DELAY_MS}ms")

  validate_number delay-ms "${DELAY_MS}"
  validate_number jitter-ms "${JITTER_MS}"
  validate_number loss-pct "${LOSS_PCT}"

  if [[ "${JITTER_MS}" != "0" && "${JITTER_MS}" != "0.0" ]]; then
    args+=("${JITTER_MS}ms")
  fi

  if [[ "${LOSS_PCT}" != "0" && "${LOSS_PCT}" != "0.0" ]]; then
    args+=(loss "${LOSS_PCT}%")
  fi

  render_shell_command "${args[@]}"
}

load_target_state() {
  set_provider_paths "${TARGET_PROVIDER}"
  state_load
  DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-${REPO_ROOT}/assets/docker/docker-compose.yml}"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${LAB_NAME}}"
  if [[ "${TARGET_PROVIDER}" == "docker" && -z "${VND_INITIAL_COMPOSE_PROJECT_NAME:-}" && "${COMPOSE_PROJECT_NAME}" == "virtual-network-delay" && "${LAB_NAME}" != "virtual-network-delay" ]]; then
    COMPOSE_PROJECT_NAME="${LAB_NAME}"
  fi
}

run_router_shell() {
  local remote_command="$1"

  case "${TARGET_PROVIDER}" in
    docker)
      if bool_is_true "${DRY_RUN}"; then
        record_dry_run docker compose -f "${DOCKER_COMPOSE_FILE}" -p "${COMPOSE_PROJECT_NAME}" exec -T router sh -lc "${remote_command}"
      else
        docker compose -f "${DOCKER_COMPOSE_FILE}" -p "${COMPOSE_PROJECT_NAME}" exec -T router sh -lc "${remote_command}"
      fi
      ;;
    kvm|vmware)
      [[ -n "${ROUTER_HOST}" ]] || fail "Missing router host. Deploy the lab or pass --router-host."
      ssh_run "${ROUTER_HOST}" "${ROUTER_SSH_USER}" "${SSH_PRIVATE_KEY_FILE}" "${remote_command}"
      ;;
    *)
      fail "Unknown provider: ${TARGET_PROVIDER}"
      ;;
  esac
}

enable_delay() {
  local netem_args
  netem_args="$(netem_command_args)"
  run_router_shell "$(remote_interface_assignment); tc qdisc replace dev \"\${iface}\" root ${netem_args}"
  if ! bool_is_true "${DRY_RUN}"; then
    state_set DELAY_ENABLED "true"
    state_set DELAY_MS "${DELAY_MS}"
    state_set JITTER_MS "${JITTER_MS}"
    state_set LOSS_PCT "${LOSS_PCT}"
    state_set ROUTER_DELAY_INTERFACE "${ROUTER_DELAY_INTERFACE}"
  fi
}

disable_delay() {
  run_router_shell "$(remote_interface_assignment); tc qdisc del dev \"\${iface}\" root 2>/dev/null || true"
  if ! bool_is_true "${DRY_RUN}"; then
    state_set DELAY_ENABLED "false"
  fi
}

status_delay() {
  run_router_shell "$(remote_interface_assignment); tc qdisc show dev \"\${iface}\""
}

main() {
  load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
  refresh_derived_defaults
  TARGET_PROVIDER="${PROVIDER:-${TARGET_PROVIDER}}"
  [[ -n "${ACTION}" ]] || fail "Missing action. Use status, enable, or disable."
  preparse_provider "$@"
  load_target_state
  parse_args "$@"

  case "${ACTION}" in
    status)
      status_delay
      ;;
    enable)
      enable_delay
      ;;
    disable)
      disable_delay
      ;;
    *)
      fail "Unknown action: ${ACTION}"
      ;;
  esac
}

main "$@"
