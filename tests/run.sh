#!/usr/bin/env bash
# Runs all unit tests. No root privileges or block devices are required.

set -Eeuo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "${TESTS_DIR}/.." && pwd -P)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gentoo-installer-tests.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

export GI_TEST_ROOT="$PROJECT_ROOT"
export GI_SCRIPT_DIR="$PROJECT_ROOT"
export GI_LOG_DIR="$TMP_ROOT/logs"
mkdir -p "$GI_LOG_DIR"

failed=0
total=0
for test_file in "${TESTS_DIR}"/unit/test_*.sh; do
    [[ -f $test_file ]] || continue
    total=$((total + 1))
    name=$(basename -- "$test_file" .sh)
    test_tmp="${TMP_ROOT}/${name}"
    mkdir -p "${test_tmp}/work/logs"
    printf '== %s\n' "$name"
    if GI_TEST_TMP="$test_tmp" \
        GI_WORKDIR="${test_tmp}/work" \
        GI_CONFIG_FILE="${test_tmp}/work/install.conf" \
        GI_STATE_FILE="${test_tmp}/work/state" \
        GI_LOG_FILE="${test_tmp}/work/logs/install.log" \
        bash "$test_file"; then
        printf '   ok\n'
    else
        printf '   FAILED\n'
        failed=$((failed + 1))
    fi
done

printf '\n%d test files, %d failed\n' "$total" "$failed"
((failed == 0))
