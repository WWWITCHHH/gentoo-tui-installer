#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"

EXAMPLE="${GI_TEST_ROOT}/conf/installer.conf.example"
[[ -f $EXAMPLE ]] || {
    printf '  FAIL: example configuration missing: %s\n' "$EXAMPLE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    finish_tests
}

for key in "${CONFIG_KEYS[@]}"; do
    if ! grep -qE "^${key}=\"" "$EXAMPLE"; then
        printf '  FAIL: example misses key %s\n' "$key"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
done

duplicates=$(grep -oE '^[A-Z][A-Z0-9_]*=' "$EXAMPLE" | sort | uniq -d || true)
assert_eq "" "$duplicates" "example has no duplicate keys"
assert_fail "example has no PASSWORD key" grep -qE '^PASSWORD=' "$EXAMPLE"

config_defaults
config_load "$EXAMPLE"
config_derived
assert_eq "1" "$CFG_SCHEMA"
assert_eq "uefi" "$CFG_BOOT_MODE"
assert_eq "xfs" "$CFG_ROOT_FS"
assert_eq "openrc" "$CFG_INIT"
assert_eq "bin" "$CFG_KERNEL_MODE"
assert_eq "quiet" "$CFG_KERNEL_CMDLINE"
assert_eq "gentoo" "$CFG_HOSTNAME"

# The example must not contain credentials even in comments that look like keys.
assert_not_contains "$(<"$EXAMPLE")" 'PASSWORD="' "example contains no password value"

finish_tests
