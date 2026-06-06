#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET_PROVIDER="${PROVIDER:-docker}"
SKIP_PREREQUISITES="${SKIP_PREREQUISITES:-false}"
RESTORE_DELAY="${RESTORE_DELAY:-false}"

load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
refresh_derived_defaults
TARGET_PROVIDER="${PROVIDER:-${TARGET_PROVIDER}}"

usage() {
  cat <<'EOF'
Usage: demo-latency.sh [options]

Options:
  --provider <docker|kvm|vmware|esxi>
  --lab-name <name>
  --public-port <port>       Docker host port only
  --delay-ms <ms>
  --jitter-ms <ms>
  --loss-pct <percent>
  --restore-delay            Disable delay after validation
  --skip-prerequisites
  --dry-run
  --help
EOF
}

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
    --public-port)
      DOCKER_PUBLIC_PORT="${2:?missing value for --public-port}"
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
    --restore-delay)
      RESTORE_DELAY=true
      shift
      ;;
    --skip-prerequisites)
      SKIP_PREREQUISITES=true
      shift
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

if ! bool_is_true "${SKIP_PREREQUISITES}" && ! bool_is_true "${DRY_RUN}"; then
  bash "${SCRIPT_DIR}/check-prerequisites.sh" --provider "${TARGET_PROVIDER}"
fi

deploy_args=()
validate_args=(
  --provider "${TARGET_PROVIDER}"
  --lab-name "${LAB_NAME}"
  --delay-ms "${DELAY_MS}"
  --jitter-ms "${JITTER_MS}"
  --loss-pct "${LOSS_PCT}"
)
[[ -n "${LAB_NAME}" ]] && deploy_args+=(--lab-name "${LAB_NAME}")
bool_is_true "${DRY_RUN}" && deploy_args+=(--dry-run)
bool_is_true "${RESTORE_DELAY}" && validate_args+=(--restore-delay)

case "${TARGET_PROVIDER}" in
  docker)
    [[ -n "${DOCKER_PUBLIC_PORT:-}" ]] && deploy_args+=(--public-port "${DOCKER_PUBLIC_PORT}")
    bash "${SCRIPT_DIR}/docker-lab.sh" deploy "${deploy_args[@]}"
    ;;
  kvm)
    bash "${SCRIPT_DIR}/kvm-lab.sh" deploy "${deploy_args[@]}"
    ;;
  vmware)
    bash "${SCRIPT_DIR}/vmware-lab.sh" deploy "${deploy_args[@]}"
    ;;
  esxi)
    bash "${SCRIPT_DIR}/esxi-lab.sh" deploy "${deploy_args[@]}"
    ;;
  *)
    fail "Unknown provider: ${TARGET_PROVIDER}"
    ;;
esac

if ! bool_is_true "${DRY_RUN}"; then
  bash "${SCRIPT_DIR}/validate-router-delay.sh" validate "${validate_args[@]}"
else
  printf 'planned_validate_command=%s\n' "$(render_shell_command bash scripts/validate-router-delay.sh validate "${validate_args[@]}")"
fi
