#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET_PROVIDER="${PROVIDER:-docker}"
DESTROY_YES=false

load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
refresh_derived_defaults
TARGET_PROVIDER="${PROVIDER:-${TARGET_PROVIDER}}"

usage() {
  cat <<'EOF'
Usage: destroy-virtual-network-delay.sh --provider docker|kvm|vmware|esxi --yes

Options:
  --provider <docker|kvm|vmware|esxi>
  --lab-name <name>
  --yes
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

bool_is_true "${DESTROY_YES}" || fail "Refusing to destroy without --yes."

case "${TARGET_PROVIDER}" in
  docker)
    bash "${SCRIPT_DIR}/docker-lab.sh" destroy --lab-name "${LAB_NAME}" --yes
    ;;
  kvm)
    bash "${SCRIPT_DIR}/kvm-lab.sh" destroy --lab-name "${LAB_NAME}" --yes
    ;;
  vmware)
    bash "${SCRIPT_DIR}/vmware-lab.sh" destroy --lab-name "${LAB_NAME}" --yes
    ;;
  esxi)
    bash "${SCRIPT_DIR}/esxi-lab.sh" destroy --lab-name "${LAB_NAME}" --yes
    ;;
  *)
    fail "Unknown provider: ${TARGET_PROVIDER}"
    ;;
esac
