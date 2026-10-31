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
for label in '<Back>' '<Next>' '<Save>' '<Help>' '<Exit>'; do
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
assert_contains "$footer" "<Back>" "footer includes the action bar"

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

# ---------------------------------------------------------------------------
# Standardized choice markers and choice windows
# ---------------------------------------------------------------------------
assert_eq "[ ]" "$(ui_choice_marker multi 0)" "unselected multi marker"
assert_eq "[*]" "$(ui_choice_marker multi 1)" "selected multi marker"
assert_eq "( )" "$(ui_choice_marker single 0)" "unselected single marker"
assert_eq "(*)" "$(ui_choice_marker single 1)" "selected single marker"

UI_KEY_QUEUE=()
mock_keys() {
    UI_KEY_QUEUE=("$@")
}
ui_read_key() {
    ((${#UI_KEY_QUEUE[@]})) || return 1
    UI_KEY=${UI_KEY_QUEUE[0]}
    UI_KEY_QUEUE=("${UI_KEY_QUEUE[@]:1}")
    return 0
}

mock_keys down space enter enter
assert_ok "single choice confirms the focused item" \
    ui_choice single "Title" "Subtitle" a "a|Alpha|" "b|Beta|" >/dev/null
assert_eq "b" "$UI_RESULT" "single choice returns the selected tag"
assert_eq "0" "$UI_CANCELLED" "single choice clears the cancelled flag"

mock_keys down space down down enter
assert_ok "single choice keeps an explicit Space selection" \
    ui_choice single "Title" "Subtitle" "" "a|Alpha|" "b|Beta|" "c|Gamma|" >/dev/null
assert_eq "b" "$UI_RESULT" "single choice keeps the item chosen with Space"

mock_keys end down enter
assert_ok "single choice falls back to the focused item" \
    ui_choice single "Title" "Subtitle" "" "a|Alpha|" "b|Beta|" "c|Gamma|" >/dev/null
assert_eq "c" "$UI_RESULT" "Next without Space uses the focused item"

mock_keys down enter enter
assert_ok "Enter does not change a single choice" \
    ui_choice single "Title" "Subtitle" a "a|Alpha|" "b|Beta|" >/dev/null
assert_eq "a" "$UI_RESULT" "only Space changes a single choice"

mock_keys esc
assert_fail "single choice can be cancelled" \
    ui_choice single "Title" "Subtitle" a "a|Alpha|" >/dev/null
assert_eq "1" "$UI_CANCELLED" "Esc marks the choice as cancelled"

mock_keys space down space down down enter
assert_ok "multi choice accepts several items" \
    ui_choice multi "Title" "Subtitle" a "a|Alpha|" "b|Beta|" "c|Gamma|" >/dev/null
assert_eq "b" "${UI_RESULTS[*]}" "multi choice returns the toggled tags"

mock_keys enter
assert_ok "action menu confirms with Enter" \
    ui_menu "Menu" "Subtitle" "" "one|One|" "two|Two|" >/dev/null
assert_eq "one" "$UI_RESULT" "action menu returns the focused action"

# ---------------------------------------------------------------------------
# Modal confirmation and the reusable form page
# ---------------------------------------------------------------------------
mock_keys right enter
assert_ok "modal confirm accepts after moving to Confirm" \
    ui_modal_confirm "Confirm" "Body" no >/dev/null

mock_keys enter
assert_fail "modal confirm cancels on the default button" \
    ui_modal_confirm "Confirm" "Body" no >/dev/null

PAGE_EDITED=""
test_page_rows() { UI_PAGE_ROWS=("a|Alpha|1|" "b|Beta|2|"); }
test_page_edit() { PAGE_EDITED=$1; }

mock_keys enter down down enter
assert_ok "page reaches Next after editing a row" \
    ui_page_run "Page" "Subtitle" test_page_rows test_page_edit >/dev/null
assert_eq "a" "$PAGE_EDITED" "page passes the row tag to the editor"

mock_keys esc
assert_fail "page returns Back on Esc" \
    ui_page_run "Page" "Subtitle" test_page_rows test_page_edit >/dev/null

mock_keys exit_action
set +e
ui_page_run "Page" "Subtitle" test_page_rows test_page_edit >/dev/null
PAGE_RC=$?
set -e
assert_eq "2" "$PAGE_RC" "page returns Exit on F10"

blocking_validate() { UI_PAGE_MESSAGE="blocked"; return 1; }
mock_keys down down enter esc
set +e
ui_page_run "Page" "Subtitle" test_page_rows test_page_edit blocking_validate >/dev/null
PAGE_RC=$?
set -e
assert_eq "1" "$PAGE_RC" "page stays when validation fails"
assert_eq "blocked" "$UI_PAGE_MESSAGE" "page keeps the validation message"

# Unattended installation must not wait for a key.
GI_UNATTENDED=1
UI_KEY_QUEUE=()
assert_ok "ui_pause is a no-op while unattended" ui_pause "Enter"
assert_eq "" "$UI_KEY" "unattended pause does not consume a key"
GI_UNATTENDED=0

finish_tests
