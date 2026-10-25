#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"
source "${GI_TEST_ROOT}/lib/ui.sh"
source "${GI_TEST_ROOT}/lib/wizard.sh"

# wizard_bool must return exactly yes/no even when the TUI writes to stdout.
UI_CONFIRM_RC=0
ui_confirm() {
    printf 'ANSI-NOISE\n'
    return "$UI_CONFIRM_RC"
}

UI_CONFIRM_RC=0
assert_eq "yes" "$(wizard_bool "title" "question" yes 2>/dev/null)" \
    "wizard_bool captures only yes"
UI_CONFIRM_RC=1
assert_eq "no" "$(wizard_bool "title" "question" yes 2>/dev/null)" \
    "wizard_bool captures only no"
UI_CONFIRM_RC=0
noisy=$(wizard_bool "title" "question" no 2>/dev/null)
assert_eq "yes" "$noisy"
assert_not_contains "$noisy" "ANSI-NOISE" "wizard_bool does not capture TUI output"

# ui_password_twice must keep the secret out of UI_RESULT.
ui_password() {
    UI_RESULT="s3cret-value"
    return 0
}
UI_RESULT="leftover"
UI_SECRET="leftover"
ui_password_twice "test password" >/dev/null
assert_eq "s3cret-value" "$UI_SECRET" "password is stored in UI_SECRET"
assert_eq "" "$UI_RESULT" "UI_RESULT is cleared after password entry"

UI_RESULT="leftover"
UI_SECRET="leftover"
ui_password_twice "test password" >/dev/null
assert_eq "" "$UI_RESULT" "UI_RESULT is cleared on repeated password entry"
assert_not_contains "$UI_SECRET" "leftover" "old secret is replaced"

finish_tests
