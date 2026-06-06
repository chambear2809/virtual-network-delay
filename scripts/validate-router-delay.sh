#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift || true

TARGET_PROVIDER="${PROVIDER:-docker}"
PROBE_URL="${PROBE_URL:-}"
SAMPLES="${SAMPLES:-7}"
TOLERANCE_MS="${TOLERANCE_MS:-35}"
OBSERVE_ONLY="${OBSERVE_ONLY:-false}"
RESTORE_DELAY="${RESTORE_DELAY:-false}"

usage() {
  cat <<'EOF'
Usage: validate-router-delay.sh validate [options]

Options:
  --provider <docker|kvm|vmware>
  --lab-name <name>
  --probe-url <url>
  --delay-ms <ms>
  --jitter-ms <ms>
  --loss-pct <percent>
  --samples <count>
  --tolerance-ms <ms>
  --router-host <host>
  --ssh-key <path>
  --ssh-user <user>
  --interface <name>
  --observe-only
  --restore-delay
  --help

Test-only environment:
  VALIDATE_ROUTER_DELAY_BASELINE_SAMPLES_MS=10,12,11
  VALIDATE_ROUTER_DELAY_DELAYED_SAMPLES_MS=160,170,165
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
      --probe-url)
        PROBE_URL="${2:?missing value for --probe-url}"
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
      --samples)
        SAMPLES="${2:?missing value for --samples}"
        shift 2
        ;;
      --tolerance-ms)
        TOLERANCE_MS="${2:?missing value for --tolerance-ms}"
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
      --interface)
        ROUTER_DELAY_INTERFACE="${2:?missing value for --interface}"
        shift 2
        ;;
      --observe-only)
        OBSERVE_ONLY=true
        shift
        ;;
      --restore-delay)
        RESTORE_DELAY=true
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

median_csv() {
  local csv="$1"

  printf '%s\n' "${csv}" \
    | tr ',' '\n' \
    | awk 'NF { print $1 }' \
    | sort -n \
    | awk '
      { values[NR] = $1 }
      END {
        if (NR == 0) {
          exit 1
        }
        if (NR % 2 == 1) {
          print values[(NR + 1) / 2]
        } else {
          print (values[NR / 2] + values[NR / 2 + 1]) / 2
        }
      }'
}

collect_samples_ms() {
  local url="$1"
  local samples="$2"
  local output=""
  local elapsed_seconds
  local elapsed_ms
  local index

  require_cmd curl
  for ((index = 0; index < samples; index += 1)); do
    elapsed_seconds="$(curl -o /dev/null -sS -w '%{time_total}' "${url}")"
    elapsed_ms="$(awk -v seconds="${elapsed_seconds}" 'BEGIN { printf "%.0f", seconds * 1000 }')"
    output="${output},${elapsed_ms}"
  done

  printf '%s\n' "${output#,}"
}

control_router_delay() {
  local action="$1"
  local args=("${action}" --provider "${TARGET_PROVIDER}" --lab-name "${LAB_NAME}")

  [[ -n "${ROUTER_DELAY_INTERFACE}" ]] && args+=(--interface "${ROUTER_DELAY_INTERFACE}")
  [[ -n "${ROUTER_HOST}" ]] && args+=(--router-host "${ROUTER_HOST}")
  [[ -n "${SSH_PRIVATE_KEY_FILE}" ]] && args+=(--ssh-key "${SSH_PRIVATE_KEY_FILE}")
  [[ -n "${ROUTER_SSH_USER}" ]] && args+=(--ssh-user "${ROUTER_SSH_USER}")

  if [[ "${action}" == "enable" ]]; then
    args+=(--delay-ms "${DELAY_MS}" --jitter-ms "${JITTER_MS}" --loss-pct "${LOSS_PCT}")
  fi

  bash "${SCRIPT_DIR}/router-delay.sh" "${args[@]}"
}

validate_delta() {
  local baseline_samples="$1"
  local delayed_samples="$2"
  local baseline_median
  local delayed_median
  local delta
  local threshold

  baseline_median="$(median_csv "${baseline_samples}")"
  delayed_median="$(median_csv "${delayed_samples}")"
  delta="$(awk -v delayed="${delayed_median}" -v baseline="${baseline_median}" 'BEGIN { printf "%.0f", delayed - baseline }')"
  threshold="$(awk -v delay="${DELAY_MS}" -v tolerance="${TOLERANCE_MS}" 'BEGIN { printf "%.0f", delay - tolerance }')"

  printf 'baseline_median_ms=%s\n' "${baseline_median}"
  printf 'delayed_median_ms=%s\n' "${delayed_median}"
  printf 'delta_ms=%s\n' "${delta}"
  printf 'expected_delay_ms=%s\n' "${DELAY_MS}"
  printf 'tolerance_ms=%s\n' "${TOLERANCE_MS}"

  awk -v delta="${delta}" -v threshold="${threshold}" 'BEGIN { exit !(delta >= threshold) }' \
    || fail "Observed median delta ${delta}ms is below threshold ${threshold}ms."
}

load_target_state() {
  set_provider_paths "${TARGET_PROVIDER}"
  state_load
  PROBE_URL="${PROBE_URL:-${ROUTER_PUBLIC_URL:-}}"
}

validate_probe() {
  local baseline_samples
  local delayed_samples
  local controlled_delay=false

  [[ -n "${PROBE_URL}" ]] || fail "Missing --probe-url and no ROUTER_PUBLIC_URL in state."
  [[ "${SAMPLES}" =~ ^[0-9]+$ && "${SAMPLES}" -ge 1 ]] || fail "--samples must be a positive integer."

  if [[ -n "${VALIDATE_ROUTER_DELAY_BASELINE_SAMPLES_MS:-}" && -n "${VALIDATE_ROUTER_DELAY_DELAYED_SAMPLES_MS:-}" ]]; then
    baseline_samples="${VALIDATE_ROUTER_DELAY_BASELINE_SAMPLES_MS}"
    delayed_samples="${VALIDATE_ROUTER_DELAY_DELAYED_SAMPLES_MS}"
  elif ! bool_is_true "${OBSERVE_ONLY}"; then
    control_router_delay disable
    sleep 2
    baseline_samples="$(collect_samples_ms "${PROBE_URL}" "${SAMPLES}")"
    control_router_delay enable
    controlled_delay=true
    sleep 2
    delayed_samples="$(collect_samples_ms "${PROBE_URL}" "${SAMPLES}")"
    if bool_is_true "${RESTORE_DELAY}"; then
      control_router_delay disable
      controlled_delay=false
    fi
  else
    baseline_samples="0"
    delayed_samples="$(collect_samples_ms "${PROBE_URL}" "${SAMPLES}")"
  fi

  validate_delta "${baseline_samples}" "${delayed_samples}"
  if bool_is_true "${controlled_delay}"; then
    printf 'delay_state=enabled\n'
    printf 'disable_command=bash scripts/router-delay.sh disable --provider %s\n' "${TARGET_PROVIDER}"
  elif bool_is_true "${RESTORE_DELAY}"; then
    printf 'delay_state=disabled\n'
  fi
}

main() {
  load_env_file "${ENV_FILE:-${REPO_ROOT}/.env}"
  refresh_derived_defaults
  TARGET_PROVIDER="${PROVIDER:-${TARGET_PROVIDER}}"
  [[ -n "${ACTION}" ]] || fail "Missing action. Use validate."
  preparse_provider "$@"
  load_target_state
  parse_args "$@"

  case "${ACTION}" in
    validate)
      validate_probe
      ;;
    *)
      fail "Unknown action: ${ACTION}"
      ;;
  esac
}

main "$@"
