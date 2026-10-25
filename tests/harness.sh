#!/usr/bin/env bash
# Minimal assertion helpers for installer unit tests.

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
    local expected=$1 actual=$2 message=${3:-}
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ $expected == "$actual" ]]; then
        return 0
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: [%s]\n    actual:   [%s]\n' \
        "${message:-assert_eq}" "$expected" "$actual"
}

assert_ne() {
    local unexpected=$1 actual=$2 message=${3:-}
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ $unexpected != "$actual" ]]; then
        return 0
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    unexpected: [%s]\n' "${message:-assert_ne}" "$unexpected"
}

assert_contains() {
    local haystack=$1 needle=$2 message=${3:-}
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ $haystack == *"$needle"* ]]; then
        return 0
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    missing: [%s]\n    text:    [%s]\n' \
        "${message:-assert_contains}" "$needle" "$haystack"
}

assert_not_contains() {
    local haystack=$1 needle=$2 message=${3:-}
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ $haystack != *"$needle"* ]]; then
        return 0
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    unexpected: [%s]\n    text:       [%s]\n' \
        "${message:-assert_not_contains}" "$needle" "$haystack"
}

assert_ok() {
    local message=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        return 0
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s (command returned non-zero)\n' "$message"
}

assert_fail() {
    local message=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FAIL: %s (command unexpectedly succeeded)\n' "$message"
        return 0
    fi
    return 0
}

# Like assert_fail, but runs the command in a subshell. Use it for functions
# that call die(), which exits the shell instead of returning non-zero.
assert_fail_isolated() {
    local message=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ( "$@" ) >/dev/null 2>&1; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FAIL: %s (command unexpectedly succeeded)\n' "$message"
        return 0
    fi
    return 0
}

finish_tests() {
    if ((TESTS_FAILED > 0)); then
        printf '  %d/%d assertions failed\n' "$TESTS_FAILED" "$TESTS_RUN"
        exit 1
    fi
    printf '  %d assertions passed\n' "$TESTS_RUN"
    exit 0
}
