#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local enable_output
  local disable_output
  local status_output
  local explicit_output
  local validate_output

  enable_output="$(bash "${REPO_ROOT}/scripts/router-delay.sh" enable --provider docker --delay-ms 150 --jitter-ms 20 --loss-pct 1 --dry-run)"
  assert_contains "${enable_output}" "netem\\ delay\\ 150ms\\ 20ms\\ loss\\ 1%"
  assert_contains "${enable_output}" "ip\\ route\\ show\\ default"
  assert_contains "${enable_output}" 'tc\ qdisc\ replace\ dev\ \"\$\{iface\}\"\ root'

  disable_output="$(bash "${REPO_ROOT}/scripts/router-delay.sh" disable --provider docker --dry-run)"
  assert_contains "${disable_output}" 'tc\ qdisc\ del\ dev\ \"\$\{iface\}\"\ root'

  status_output="$(bash "${REPO_ROOT}/scripts/router-delay.sh" status --provider docker --dry-run)"
  assert_contains "${status_output}" 'tc\ qdisc\ show\ dev\ \"\$\{iface\}\"'

  explicit_output="$(bash "${REPO_ROOT}/scripts/router-delay.sh" status --provider docker --interface eth9 --dry-run)"
  assert_contains "${explicit_output}" "iface=eth9"
  assert_contains "${explicit_output}" 'tc\ qdisc\ show\ dev\ \"\$\{iface\}\"'

  status_output="$(bash "${REPO_ROOT}/scripts/router-delay.sh" status --provider docker --lab-name demo-a --dry-run)"
  assert_contains "${status_output}" "-p demo-a"

  validate_output="$(
    VALIDATE_ROUTER_DELAY_BASELINE_SAMPLES_MS="9,10,11,12,13" \
      VALIDATE_ROUTER_DELAY_DELAYED_SAMPLES_MS="160,165,170,175,180" \
      bash "${REPO_ROOT}/scripts/validate-router-delay.sh" validate \
        --provider docker \
        --probe-url http://example.invalid/ \
        --delay-ms 150 \
        --tolerance-ms 20
  )"
  assert_contains "${validate_output}" "baseline_median_ms=11"
  assert_contains "${validate_output}" "delayed_median_ms=170"
  assert_contains "${validate_output}" "delta_ms=159"

  validate_output="$(bash "${REPO_ROOT}/scripts/validate-router-delay.sh" validate --help)"
  assert_contains "${validate_output}" "--restore-delay"

  pass_test "router delay commands and validation math"
}

main "$@"
