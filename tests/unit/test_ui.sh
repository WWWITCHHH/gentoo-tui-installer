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

# ---------------------------------------------------------------------------
# Bottom action bar, summary and function-key decoding
# ---------------------------------------------------------------------------
bar=$(ui_action_bar)
for label in '<Select>' '<Exit>' '<Save>' '<Help>'; do
    assert_contains "$bar" "$label" "action bar includes ${label}"
done

UI_MENU_SUMMARY=()
assert_eq "" "$(ui_summary)" "summary is hidden without data"

UI_MENU_SUMMARY=(
    "Boot: UEFI · Disk: /dev/vda (20 GiB) · FS: xfs"
    "Stage3: openrc · Kernel: bin · Desktop: none"
)
summary=$(ui_summary)
assert_contains "$summary" "Current configuration" "summary has a heading"
assert_contains "$summary" "Boot: UEFI" "summary shows the boot line"
assert_contains "$summary" "Stage3: openrc" "summary shows the Stage3 line"

footer=$(ui_footer "Test hint")
assert_contains "$footer" "Test hint" "footer shows its hint"
assert_contains "$footer" "<Select>" "footer includes the action bar"

read_key_for() {
    local sequence=$1
    printf '%s' "$sequence" | {
        ui_read_key || true
        printf '%s' "$UI_KEY"
    }
}
assert_eq "up" "$(read_key_for $'\e[A')" "UP arrow is decoded"
assert_eq "down" "$(read_key_for $'\e[B')" "DOWN arrow is decoded"
assert_eq "help" "$(read_key_for $'\eOP')" "F1 opens help"
assert_eq "save" "$(read_key_for $'\eOQ')" "F2 saves the configuration"
assert_eq "save" "$(read_key_for $'\x13')" "Ctrl-S saves the configuration"
assert_eq "exit_action" "$(read_key_for $'\e[21~')" "F10 exits the current menu"
assert_eq "esc" "$(read_key_for $'\e')" "Esc returns"
assert_eq "enter" "$(read_key_for $'\n')" "Enter selects"

finish_tests
