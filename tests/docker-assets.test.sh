#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local tmp
  local output

  assert_file_contains "${REPO_ROOT}/assets/docker/docker-compose.yml" "NET_ADMIN"
  assert_file_contains "${REPO_ROOT}/assets/docker/docker-compose.yml" "net.ipv4.ip_forward"
  assert_file_contains "${REPO_ROOT}/assets/docker/docker-compose.yml" "internal: true"
  assert_file_contains "${REPO_ROOT}/assets/docker/router/Dockerfile" "FROM \${UBUNTU_IMAGE}"
  assert_file_contains "${REPO_ROOT}/assets/docker/backend/Dockerfile" "FROM \${UBUNTU_IMAGE}"

  tmp="$(make_temp_dir)"
  output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/docker-lab.sh" deploy --dry-run --public-port 18080)"
  assert_contains "${output}" "docker compose"
  assert_contains "${output}" "DOCKER_PUBLIC_PORT=18080"
  assert_contains "${output}" "router_url=http://127.0.0.1:18080/"
  assert_contains "${output}" "validate_command=bash scripts/validate-router-delay.sh validate --provider docker --delay-ms 150"
  assert_file_contains "${tmp}/state/docker/virtual-network-delay.env" "ROUTER_PUBLIC_URL=http://127.0.0.1:18080/"

  output="$(STATE_ROOT="${tmp}/state2" bash "${REPO_ROOT}/scripts/docker-lab.sh" deploy --dry-run --lab-name demo-a --public-port 18081)"
  assert_contains "${output}" "lab_name=demo-a"
  assert_contains "${output}" "validate-router-delay.sh validate --provider docker --lab-name demo-a --delay-ms 150"
  assert_file_contains "${tmp}/state2/docker/demo-a.env" "ROUTER_PUBLIC_URL=http://127.0.0.1:18081/"

  output="$(STATE_ROOT="${tmp}/state2" bash "${REPO_ROOT}/scripts/docker-lab.sh" status --dry-run --lab-name demo-a)"
  assert_contains "${output}" "docker compose"
  assert_contains "${output}" "router_url=http://127.0.0.1:18081/"

  output="$(STATE_ROOT="${tmp}/state2" bash "${REPO_ROOT}/scripts/docker-lab.sh" destroy --dry-run --lab-name demo-a --yes)"
  assert_contains "${output}" "down -v --remove-orphans"
  assert_contains "${output}" "rm -f"

  pass_test "docker assets and dry-run state"
}

main "$@"
