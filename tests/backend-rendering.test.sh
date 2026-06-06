#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local http_config
  local https_config
  local rtsp_config
  local tcp_config
  local kvm_default_config
  local vmware_default_config
  local esxi_default_config
  local unsupported_output
  local unsupported_status
  local tmp

  http_config="$(bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider docker --protocol http --backend-host backend --backend-port 8080 --public-port 80)"
  assert_contains "${http_config}" "mode http"
  assert_contains "${http_config}" "bind *:80"
  assert_contains "${http_config}" "server target backend:8080 check"

  https_config="$(bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider docker --protocol https --backend-host secure.internal --backend-port 443 --public-port 443)"
  assert_contains "${https_config}" "mode tcp"
  assert_contains "${https_config}" "bind *:443"
  assert_contains "${https_config}" "server target secure.internal:443 check"

  rtsp_config="$(bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider docker --protocol rtsp --backend-host camera.internal --backend-port 554 --public-port 8554)"
  assert_contains "${rtsp_config}" "mode tcp"
  assert_contains "${rtsp_config}" "bind *:8554"
  assert_contains "${rtsp_config}" "server target camera.internal:554 check"

  tcp_config="$(bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider docker --protocol tcp --backend-host raw.internal --backend-port 9000 --public-port 9000)"
  assert_contains "${tcp_config}" "mode tcp"
  assert_contains "${tcp_config}" "bind *:9000"
  assert_contains "${tcp_config}" "server target raw.internal:9000 check"

  tmp="$(make_temp_dir)"
  cat > "${tmp}/provider.env" <<'EOF'
BACKEND_HOST=
KVM_BACKEND_PRIVATE_IP=192.168.111.20
VMWARE_BACKEND_PRIVATE_IP=172.31.201.20
ESXI_BACKEND_PRIVATE_IP=172.31.202.20
EOF

  kvm_default_config="$(ENV_FILE="${tmp}/provider.env" STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider kvm --protocol tcp --backend-port 9001 --public-port 9001)"
  assert_contains "${kvm_default_config}" "server target 192.168.111.20:9001 check"

  vmware_default_config="$(ENV_FILE="${tmp}/provider.env" STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider vmware --protocol tcp --backend-port 9002 --public-port 9002)"
  assert_contains "${vmware_default_config}" "server target 172.31.201.20:9002 check"

  esxi_default_config="$(ENV_FILE="${tmp}/provider.env" STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider esxi --protocol tcp --backend-port 9003 --public-port 9003)"
  assert_contains "${esxi_default_config}" "server target 172.31.202.20:9003 check"

  set +e
  unsupported_output="$(bash "${REPO_ROOT}/scripts/backend-wire.sh" render --provider docker --protocol smtp --backend-host mail.internal --backend-port 25 --public-port 25 2>&1)"
  unsupported_status=$?
  set -e
  [[ "${unsupported_status}" -ne 0 ]] || fail_test "unsupported backend protocol should fail"
  assert_contains "${unsupported_output}" "Unsupported protocol: smtp"

  pass_test "backend HAProxy rendering"
}

main "$@"
