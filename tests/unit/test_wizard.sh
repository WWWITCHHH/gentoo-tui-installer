#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/i18n.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"
source "${GI_TEST_ROOT}/lib/ui.sh"
source "${GI_TEST_ROOT}/lib/desktop.sh"
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

# ---------------------------------------------------------------------------
# Compact summary and configuration persistence
# ---------------------------------------------------------------------------
i18n_init en
config_defaults
STATE_DONE=([disk]=1 [stage3]=1)
CFG_UI_LANGUAGE=en
CFG_BOOT_MODE=uefi
CFG_DISK=""
CFG_ROOT_FS=xfs
CFG_HOME_MODE=no
CFG_STAGE_FLAVOR=openrc
CFG_KERNEL_MODE=bin
CFG_DESKTOP=none
CFG_LOCALE=en_US.UTF-8
wizard_update_summary
summary=${UI_MENU_SUMMARY[*]}
assert_contains "$summary" "Boot: UEFI" "summary reports the boot mode"
assert_contains "$summary" "Disk: not selected" "summary reports an unset disk"
assert_contains "$summary" "FS: xfs" "summary reports the root filesystem"
assert_contains "$summary" "Stage3: openrc" "summary reports the Stage3 flavor"
assert_contains "$summary" "Kernel: bin" "summary reports the kernel method"
assert_contains "$summary" "Progress: 2/9 steps" "summary reports step progress"
assert_contains "$summary" "Language: English" "summary reports the UI language"

i18n_init ru
CFG_UI_LANGUAGE=ru
CFG_LOCALE=ru_RU.UTF-8
wizard_update_summary
summary=${UI_MENU_SUMMARY[*]}
assert_contains "$summary" "Загрузка: UEFI" "summary is translated into Russian"
assert_contains "$summary" "Язык: Русский" "Russian summary reports the UI language"
i18n_init en

# Passwords are interactive-only: saving the configuration must not persist a
# secret from the environment or the TUI state.
config_defaults
config_derived
UI_SECRET="top-secret-password"
wizard_save
config_text=$(<"$GI_CONFIG_FILE")
assert_not_contains "$config_text" "top-secret-password" "config save never writes UI_SECRET"
assert_not_contains "$config_text" "PASSWORD" "config save never writes a password key"
assert_contains "$config_text" 'UI_LANGUAGE="en"' "config save persists the UI language"

finish_tests
