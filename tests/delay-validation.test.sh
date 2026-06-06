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
  local kvm_enable_output
  local esxi_enable_output
  local validate_output
  local controlled_output
  local direct_output
  local direct_status
  local tmp

  tmp="$(make_temp_dir)"

  enable_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/router-delay.sh" enable --provider docker --delay-ms 150 --jitter-ms 20 --loss-pct 1 --dry-run)"
  assert_contains "${enable_output}" "netem\\ delay\\ 150ms\\ 20ms\\ loss\\ 1%"
  assert_contains "${enable_output}" "ip\\ route\\ show\\ default"
  assert_contains "${enable_output}" 'tc\ qdisc\ replace\ dev\ \"\$\{iface\}\"\ root'

  disable_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/router-delay.sh" disable --provider docker --dry-run)"
  assert_contains "${disable_output}" 'tc\ qdisc\ del\ dev\ \"\$\{iface\}\"\ root'

  status_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/router-delay.sh" status --provider docker --dry-run)"
  assert_contains "${status_output}" 'tc\ qdisc\ show\ dev\ \"\$\{iface\}\"'

  explicit_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/router-delay.sh" status --provider docker --interface eth9 --dry-run)"
  assert_contains "${explicit_output}" "iface=eth9"
  assert_contains "${explicit_output}" 'tc\ qdisc\ show\ dev\ \"\$\{iface\}\"'

  status_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/router-delay.sh" status --provider docker --lab-name demo-a --dry-run)"
  assert_contains "${status_output}" "-p demo-a"

  kvm_enable_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/router-delay.sh" enable --provider kvm --router-host 192.0.2.10 --ssh-key /tmp/vnd-test-key --delay-ms 150 --dry-run)"
  assert_contains "${kvm_enable_output}" "ssh"
  assert_contains "${kvm_enable_output}" "sudo\\ sh\\ -lc"
  assert_contains "${kvm_enable_output}" "qdisc"
  assert_contains "${kvm_enable_output}" "replace"
  assert_contains "${kvm_enable_output}" "netem"

  esxi_enable_output="$(STATE_ROOT="${tmp}/state" bash "${REPO_ROOT}/scripts/router-delay.sh" enable --provider esxi --router-host 192.0.2.20 --ssh-key /tmp/vnd-test-key --delay-ms 150 --dry-run)"
  assert_contains "${esxi_enable_output}" "ssh"
  assert_contains "${esxi_enable_output}" "sudo\\ sh\\ -lc"
  assert_contains "${esxi_enable_output}" "qdisc"
  assert_contains "${esxi_enable_output}" "replace"
  assert_contains "${esxi_enable_output}" "netem"

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

  mkdir -p "${tmp}/bin"
  cat > "${tmp}/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${tmp}/bin/curl" <<'EOF'
#!/usr/bin/env bash
count_file="${MOCK_CURL_COUNT_FILE:?}"
count=0
if [[ -f "${count_file}" ]]; then
  count="$(cat "${count_file}")"
fi
count=$((count + 1))
printf '%s\n' "${count}" > "${count_file}"
if [[ "${count}" -le 3 ]]; then
  printf '0.010'
else
  printf '0.170'
fi
EOF
  cat > "${tmp}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${tmp}/bin/docker" "${tmp}/bin/curl" "${tmp}/bin/sleep"

  controlled_output="$(
    PATH="${tmp}/bin:${PATH}" \
      MOCK_CURL_COUNT_FILE="${tmp}/curl-count" \
      STATE_ROOT="${tmp}/state" \
      bash "${REPO_ROOT}/scripts/validate-router-delay.sh" validate \
        --provider docker \
        --lab-name demo-a \
        --probe-url http://127.0.0.1:18080/ \
        --delay-ms 150 \
        --samples 3 \
        --tolerance-ms 20
  )"
  assert_contains "${controlled_output}" "delay_state=enabled"
  assert_contains "${controlled_output}" "disable_command=bash scripts/router-delay.sh disable --provider docker --lab-name demo-a"

  set +e
  direct_output="$(
    BACKEND_HOST=backend \
      VALIDATE_ROUTER_DELAY_BASELINE_SAMPLES_MS="9,10,11" \
      VALIDATE_ROUTER_DELAY_DELAYED_SAMPLES_MS="160,165,170" \
      bash "${REPO_ROOT}/scripts/validate-router-delay.sh" validate \
        --provider docker \
        --probe-url http://backend:8080/ \
        --delay-ms 150 \
        2>&1
  )"
  direct_status=$?
  set -e
  [[ "${direct_status}" -ne 0 ]] || fail_test "direct backend probe should fail"
  assert_contains "${direct_output}" "matches BACKEND_HOST"
  assert_contains "${direct_output}" "client -> router -> private backend"

  set +e
  direct_output="$(
    BACKEND_HOST=172.31.202.20 \
      VALIDATE_ROUTER_DELAY_BASELINE_SAMPLES_MS="9,10,11" \
      VALIDATE_ROUTER_DELAY_DELAYED_SAMPLES_MS="160,165,170" \
      bash "${REPO_ROOT}/scripts/validate-router-delay.sh" validate \
        --provider esxi \
        --probe-url http://172.31.202.20:8080/ \
        --delay-ms 150 \
        2>&1
  )"
  direct_status=$?
  set -e
  [[ "${direct_status}" -ne 0 ]] || fail_test "direct ESXi backend probe should fail"
  assert_contains "${direct_output}" "matches BACKEND_HOST"
  assert_contains "${direct_output}" "client -> router -> private backend"

  validate_output="$(bash "${REPO_ROOT}/scripts/validate-router-delay.sh" validate --help)"
  assert_contains "${validate_output}" "--restore-delay"

  pass_test "router delay commands and validation math"
}

main "$@"
