#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift || true

PROVIDER="docker"
set_provider_paths "${PROVIDER}"

DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-${REPO_ROOT}/assets/docker/docker-compose.yml}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${LAB_NAME}}"
DOCKER_PUBLIC_BIND="${DOCKER_PUBLIC_BIND:-127.0.0.1}"
DOCKER_PUBLIC_PORT="${DOCKER_PUBLIC_PORT:-8080}"

usage() {
  cat <<'EOF'
Usage: docker-lab.sh <deploy|status|destroy> [options]

Options:
  --lab-name <name>
  --public-port <host-port>  Default: 8080
  --public-bind <address>    Default: 127.0.0.1
  --dry-run
  --yes
  --help
EOF
}

parse_args() {
  DESTROY_YES="${DESTROY_YES:-false}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab-name)
        LAB_NAME="${2:?missing value for --lab-name}"
        COMPOSE_PROJECT_NAME="${LAB_NAME}"
        set_provider_paths "${PROVIDER}"
        shift 2
        ;;
      --public-port)
        DOCKER_PUBLIC_PORT="${2:?missing value for --public-port}"
        shift 2
        ;;
      --public-bind)
        DOCKER_PUBLIC_BIND="${2:?missing value for --public-bind}"
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

docker_compose() {
  run_cmd env \
    "DOCKER_UBUNTU_IMAGE=${DOCKER_UBUNTU_IMAGE}" \
    "DOCKER_PUBLIC_BIND=${DOCKER_PUBLIC_BIND}" \
    "DOCKER_PUBLIC_PORT=${DOCKER_PUBLIC_PORT}" \
    "BACKEND_HOST=${BACKEND_HOST:-backend}" \
    "BACKEND_PROTOCOL=${BACKEND_PROTOCOL}" \
    "BACKEND_PORT=${BACKEND_PORT}" \
    "PUBLIC_PORT=${PUBLIC_PORT}" \
    docker compose -f "${DOCKER_COMPOSE_FILE}" -p "${COMPOSE_PROJECT_NAME}" "$@"
}

deploy_lab() {
  validate_port docker-public-port "${DOCKER_PUBLIC_PORT}"
  validate_port backend-port "${BACKEND_PORT}"
  validate_port public-port "${PUBLIC_PORT}"

  if ! bool_is_true "${DRY_RUN}"; then
    require_cmd docker
    require_cmd curl
    docker info >/dev/null 2>&1 || fail "Docker is installed, but the daemon is not reachable. Start Docker Desktop or the Docker service, then retry."
  fi
  state_note_defaults
  state_set DOCKER_COMPOSE_FILE "${DOCKER_COMPOSE_FILE}"
  state_set COMPOSE_PROJECT_NAME "${COMPOSE_PROJECT_NAME}"
  state_set DOCKER_PUBLIC_BIND "${DOCKER_PUBLIC_BIND}"
  state_set DOCKER_PUBLIC_PORT "${DOCKER_PUBLIC_PORT}"
  state_set ROUTER_HOST "127.0.0.1"
  state_set ROUTER_PUBLIC_URL "http://${DOCKER_PUBLIC_BIND}:${DOCKER_PUBLIC_PORT}/"
  state_set BACKEND_HOST "backend"
  state_set BACKEND_PORT "${BACKEND_PORT}"
  state_set PUBLIC_PORT "${PUBLIC_PORT}"

  docker_compose build
  docker_compose up -d
  ROUTER_PUBLIC_URL="http://${DOCKER_PUBLIC_BIND}:${DOCKER_PUBLIC_PORT}/"
  wait_for_http_url "${ROUTER_PUBLIC_URL}" 180
  log "Docker lab is ready."
  print_lab_summary "${PROVIDER}"
}

status_lab() {
  state_load
  docker_compose ps
  print_lab_summary "${PROVIDER}"
}

destroy_lab() {
  state_load
  if ! bool_is_true "${DESTROY_YES}"; then
    fail "Refusing to destroy without --yes."
  fi
  docker_compose down -v --remove-orphans
  run_cmd rm -f "${STATE_FILE}"
}

main() {
  load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
  refresh_derived_defaults
  PROVIDER="docker"
  set_provider_paths "${PROVIDER}"
  if [[ -z "${VND_INITIAL_COMPOSE_PROJECT_NAME:-}" && "${COMPOSE_PROJECT_NAME}" == "virtual-network-delay" && "${LAB_NAME}" != "virtual-network-delay" ]]; then
    COMPOSE_PROJECT_NAME="${LAB_NAME}"
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
