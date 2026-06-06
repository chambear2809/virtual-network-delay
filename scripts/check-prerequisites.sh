#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET_PROVIDER="${PROVIDER:-all}"

usage() {
  cat <<'EOF'
Usage: check-prerequisites.sh [--provider docker|kvm|vmware|all]
EOF
}

has_any_iso_tool() {
  command -v cloud-localds >/dev/null 2>&1 \
    || command -v genisoimage >/dev/null 2>&1 \
    || command -v mkisofs >/dev/null 2>&1 \
    || command -v hdiutil >/dev/null 2>&1
}

check_docker() {
  require_cmd docker
  require_cmd curl
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required: docker compose version failed."
  docker info >/dev/null 2>&1 || fail "Docker is installed, but the daemon is not reachable. Start Docker Desktop or the Docker service, then retry."
  log "docker prerequisites ok"
}

check_kvm() {
  local cmd
  for cmd in virsh virt-install qemu-img curl ssh ssh-keygen scp; do
    require_cmd "${cmd}"
  done
  has_any_iso_tool || fail "Need one NoCloud seed ISO tool: cloud-localds, genisoimage, mkisofs, or hdiutil."
  log "kvm prerequisites ok"
}

check_vmware() {
  local cmd
  for cmd in vmrun qemu-img curl ssh ssh-keygen scp; do
    require_cmd "${cmd}"
  done
  has_any_iso_tool || fail "Need one NoCloud seed ISO tool: cloud-localds, genisoimage, mkisofs, or hdiutil."
  log "vmware prerequisites ok"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      TARGET_PROVIDER="${2:?missing value for --provider}"
      shift 2
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

case "${TARGET_PROVIDER}" in
  docker)
    check_docker
    ;;
  kvm)
    check_kvm
    ;;
  vmware)
    check_vmware
    ;;
  all)
    check_docker
    check_kvm
    check_vmware
    ;;
  *)
    fail "Unknown provider: ${TARGET_PROVIDER}"
    ;;
esac
