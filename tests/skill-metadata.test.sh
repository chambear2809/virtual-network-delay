#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "${TEST_DIR}/helpers.sh"

main() {
  assert_file_contains "${REPO_ROOT}/SKILL.md" "name: virtual-network-delay"
  assert_file_contains "${REPO_ROOT}/SKILL.md" "Docker, KVM/libvirt, and VMware"
  assert_file_contains "${REPO_ROOT}/SKILL.md" "One-command demo"
  assert_file_contains "${REPO_ROOT}/agents/openai.yaml" "default_prompt: \"Use \$virtual-network-delay"
  assert_file_contains "${REPO_ROOT}/README.md" "--restore-delay"
  assert_file_contains "${REPO_ROOT}/README.md" "Custom Lab Names"
  assert_file_contains "${REPO_ROOT}/references/research-notes.md" "https://man7.org/linux/man-pages/man8/tc-netem.8.html"
  assert_file_contains "${REPO_ROOT}/references/platform-contract.md" "client -> router -> private backend"

  pass_test "skill metadata and references"
}

main "$@"
