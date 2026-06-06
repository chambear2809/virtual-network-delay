#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  local script_file
  local files=(
    "${REPO_ROOT}"/scripts/*.sh
    "${REPO_ROOT}"/tests/*.sh
    "${REPO_ROOT}"/assets/docker/router/*.sh
  )

  for script_file in "${files[@]}"; do
    bash -n "${script_file}"
  done

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${files[@]}"
  else
    printf 'skip - shellcheck unavailable\n'
  fi

  pass_test "script syntax and static checks"
}

main "$@"
