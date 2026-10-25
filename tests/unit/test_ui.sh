#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"
source "${GI_TEST_ROOT}/lib/ui.sh"

assert_eq "█████░░░░░" "$(ui_progress_bar 5 10 10)"
assert_eq "░░░░░░░░░░" "$(ui_progress_bar 0 10 10)"
assert_eq "██████████" "$(ui_progress_bar 10 10 10)"
assert_eq "██████████" "$(ui_progress_bar 99 10 10)" "progress is clamped to width"

wrapped=$(ui_wrap "one two three four five" 12)
assert_contains "$wrapped" "one two" "ui_wrap includes text"
[[ $(printf '%s\n' "$wrapped" | wc -l) -ge 1 ]] || { printf '  FAIL: ui_wrap produced no lines\n'; TESTS_FAILED=$((TESTS_FAILED + 1)); }
TESTS_RUN=$((TESTS_RUN + 1))

UI_INT_MIN=1
UI_INT_MAX=10
assert_ok "int range validator" _ui_validate_int_range 5
assert_fail "int range validator out of range" _ui_validate_int_range 11
[[ -n $VALIDATION_MESSAGE ]] || { printf '  FAIL: ui int validator message missing\n'; TESTS_FAILED=$((TESTS_FAILED + 1)); }
TESTS_RUN=$((TESTS_RUN + 1))

finish_tests
