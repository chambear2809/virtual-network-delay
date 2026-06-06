#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_file in "${TEST_DIR}"/*.test.sh; do
  bash "${test_file}"
done
