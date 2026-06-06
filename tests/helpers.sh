#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
export REPO_ROOT

fail_test() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass_test() {
  printf 'ok - %s\n' "$*"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "${haystack}" == *"${needle}"* ]] || fail_test "expected output to contain: ${needle}"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"

  [[ -f "${file}" ]] || fail_test "missing file: ${file}"
  grep -F -- "${needle}" "${file}" >/dev/null || fail_test "expected ${file} to contain: ${needle}"
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/virtual-network-delay-test.XXXXXX"
}
