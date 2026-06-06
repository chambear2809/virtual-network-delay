#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local http_config
  local https_config
  local rtsp_config

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

  pass_test "backend HAProxy rendering"
}

main "$@"
