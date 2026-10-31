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

# ---------------------------------------------------------------------------
# Explicit kernel and account choices
# ---------------------------------------------------------------------------
config_defaults
assert_eq "" "$CFG_KERNEL_MODE" "the kernel method has no implicit default"
assert_eq "no" "$CFG_CREATE_USER" "no account is created by default"
assert_eq "" "$CFG_USERNAME" "no user name is invented by default"

assert_fail "kernel validation rejects an unset method" wizard_kernel_validate
assert_eq "Choose the binary, compiled or automatic kernel explicitly." "$UI_PAGE_MESSAGE"
CFG_KERNEL_MODE=bin
assert_ok "kernel validation accepts binary" wizard_kernel_validate
CFG_KERNEL_MODE=dist
assert_ok "kernel validation accepts compiled" wizard_kernel_validate
CFG_KERNEL_MODE=auto
assert_ok "kernel validation accepts the automatic generated config" wizard_kernel_validate
CFG_KERNEL_MODE=manual
assert_ok "kernel validation accepts manual" wizard_kernel_validate

config_defaults
STATE_DONE=()
GI_ROOT_PASSWORD=""
assert_fail "users page requires the root password" wizard_users_validate
assert_eq "Set the root password before continuing." "$UI_PAGE_MESSAGE"
GI_ROOT_PASSWORD="memory-only"
assert_ok "users page accepts a root password" wizard_users_validate
CFG_CREATE_USER=yes
CFG_USERNAME="Not Valid"
assert_fail "users page validates the user name" wizard_users_validate

# The review text reports only whether a password is set.
config_defaults
CFG_CREATE_USER=yes
CFG_USERNAME=alice
GI_ROOT_PASSWORD="hunter2-secret"
GI_USER_PASSWORD="correct-horse"
review=$(wizard_review_text)
assert_contains "$review" "root password: set" "review reports the root password state"
assert_not_contains "$review" "hunter2-secret" "review never prints the root password"
assert_not_contains "$review" "correct-horse" "review never prints the user password"
GI_ROOT_PASSWORD=""
assert_contains "$(wizard_review_text)" "root password: not set" \
    "review reports a missing root password"

# sudo is configured once, on the users page.
config_defaults
wizard_desktop_rows
desktop_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_not_contains "$desktop_rows" "VIDEO_CARDS" "video row is hidden without a desktop"
CFG_DESKTOP=xfce
wizard_desktop_rows
desktop_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$desktop_rows" "VIDEO_CARDS" "video row appears with a desktop"

wizard_users_rows
users_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$users_rows" "Install sudo" "users page has the sudo setting"
wizard_services_rows
services_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_not_contains "$services_rows" "Install sudo" "services page has no duplicate sudo setting"
assert_contains "$services_rows" "Network" "services page still lists the network"

# ---------------------------------------------------------------------------
# Easy and Advanced modes
# ---------------------------------------------------------------------------
config_defaults
GI_EASY_MODE=1
GI_CONFIG_EXISTED=0
GI_MODE_DEFAULTS_APPLIED=0
wizard_apply_mode_defaults
assert_eq "ext4" "$CFG_ROOT_FS" "easy mode defaults to ext4"
assert_eq "systemd" "$CFG_STAGE_FLAVOR" "easy mode defaults to systemd"
assert_eq "yes" "$CFG_UPDATE_WORLD" "easy mode defaults to @world update"

CFG_ROOT_FS=xfs
CFG_STAGE_FLAVOR=openrc
CFG_UPDATE_WORLD=no
wizard_apply_mode_defaults
assert_eq "xfs" "$CFG_ROOT_FS" "easy defaults are applied only once"
assert_eq "openrc" "$CFG_STAGE_FLAVOR" "existing stage3 choice is preserved"
assert_eq "no" "$CFG_UPDATE_WORLD" "existing @world choice is preserved"

config_defaults
GI_EASY_MODE=0
GI_CONFIG_EXISTED=0
GI_MODE_DEFAULTS_APPLIED=0
wizard_apply_mode_defaults
assert_eq "xfs" "$CFG_ROOT_FS" "advanced mode keeps the current root filesystem default"
assert_eq "openrc" "$CFG_STAGE_FLAVOR" "advanced mode keeps the current stage3 default"
assert_eq "no" "$CFG_UPDATE_WORLD" "advanced mode keeps the current @world default"

config_defaults
GI_EASY_MODE=1
GI_CONFIG_EXISTED=1
GI_MODE_DEFAULTS_APPLIED=0
CFG_ROOT_FS=btrfs
CFG_STAGE_FLAVOR=openrc
CFG_UPDATE_WORLD=no
wizard_apply_mode_defaults
assert_eq "btrfs" "$CFG_ROOT_FS" "an existing configuration keeps its root filesystem"
assert_eq "openrc" "$CFG_STAGE_FLAVOR" "an existing configuration keeps its stage3"
assert_eq "no" "$CFG_UPDATE_WORLD" "an existing configuration keeps its @world choice"

GI_EASY_MODE=1
wizard_toggle_mode
assert_eq "0" "$GI_EASY_MODE" "mode toggle switches to advanced"
wizard_toggle_mode
assert_eq "1" "$GI_EASY_MODE" "mode toggle switches back to easy"

# Easy mode hides advanced rows but keeps the target disk visible.
config_defaults
GI_EASY_MODE=1
CFG_BOOT_MODE=uefi
CFG_DISK_MODE=auto
CFG_HOME_MODE=no
CFG_HOME_MIB=0
mode_efi=$(mktemp -d "${TMPDIR:-/tmp}/gi-efi.XXXXXX")
GI_FIRMWARE_EFI_DIR=$mode_efi
wizard_disk_rows
disk_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$disk_rows" "Target disk" "easy mode keeps the target disk visible"
assert_contains "$disk_rows" "Root filesystem" "easy mode keeps the root filesystem"
assert_contains "$disk_rows" "Swap" "easy mode keeps swap"
assert_not_contains "$disk_rows" "Boot mode" "easy mode hides a non-conflicting boot mode"
assert_not_contains "$disk_rows" "Partitioning mode" "easy mode hides the partitioning mode"
assert_not_contains "$disk_rows" "/home" "easy mode hides /home"
CFG_HOME_MODE=separate
wizard_disk_rows
disk_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$disk_rows" "/home filesystem" "easy mode shows /home filesystem when /home is separate"
assert_contains "$disk_rows" "/home" "easy mode shows /home when it is separate"
CFG_HOME_MODE=no
CFG_DISK_MODE=manual
wizard_disk_rows
disk_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$disk_rows" "Partitioning mode" "easy mode shows the partitioning mode for a manual layout"
assert_contains "$disk_rows" "Assign partitions" "easy mode shows manual partition assignment"
CFG_DISK_MODE=auto
CFG_BOOT_MODE=bios
wizard_disk_rows
disk_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$disk_rows" "Boot mode" "easy mode shows a conflicting boot mode"
GI_EASY_MODE=0
CFG_BOOT_MODE=uefi
wizard_disk_rows
disk_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$disk_rows" "Boot mode" "advanced mode shows the boot mode"
assert_contains "$disk_rows" "Partitioning mode" "advanced mode shows the partitioning mode"
assert_contains "$disk_rows" "/home" "advanced mode shows /home"
unset GI_FIRMWARE_EFI_DIR
rm -rf -- "$mode_efi"

# Page filters.
config_defaults
GI_EASY_MODE=1
wizard_system_rows
system_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_not_contains "$system_rows" "Installer language" "easy mode hides the language row"
GI_EASY_MODE=0
wizard_system_rows
system_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$system_rows" "Installer language" "advanced mode shows the language row"

GI_EASY_MODE=1
wizard_build_rows
build_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$build_rows" "Init system and Stage3" "easy mode shows the init system"
assert_not_contains "$build_rows" "Mirror" "easy mode hides the mirror"
assert_not_contains "$build_rows" "CFLAGS" "easy mode hides CFLAGS"
GI_EASY_MODE=0
wizard_build_rows
build_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$build_rows" "Mirror" "advanced mode shows the mirror"
assert_contains "$build_rows" "CFLAGS" "advanced mode shows CFLAGS"

GI_EASY_MODE=1
wizard_kernel_rows
kernel_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$kernel_rows" "Kernel installation method" "easy mode shows the kernel method"
assert_not_contains "$kernel_rows" "CPU microcode" "easy mode hides microcode"
assert_not_contains "$kernel_rows" "Kernel cmdline" "easy mode hides the kernel cmdline"
GI_EASY_MODE=0
wizard_kernel_rows
kernel_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$kernel_rows" "CPU microcode" "advanced mode shows microcode"
assert_contains "$kernel_rows" "Kernel cmdline" "advanced mode shows the kernel cmdline"

# VIDEO_CARDS is read-only in easy mode only when detection produced a value.
config_defaults
GI_EASY_MODE=1
CFG_DESKTOP=xfce
CFG_VIDEO_CARDS=intel
wizard_desktop_rows
desktop_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$desktop_rows" "Advanced mode" "easy mode marks a detected VIDEO_CARDS value as read-only"
CFG_VIDEO_CARDS=""
wizard_desktop_rows
desktop_rows=$(printf '%s\n' "${UI_PAGE_ROWS[@]}")
assert_contains "$desktop_rows" "Enter to choose" "easy mode allows choosing when detection is empty"
MODE_MESSAGE=""
ui_msg() { MODE_MESSAGE=$1; }
ui_choice() { return 99; }
GI_EASY_MODE=1
CFG_VIDEO_CARDS=intel
assert_ok "easy mode refuses to edit a detected VIDEO_CARDS" wizard_desktop_edit video
assert_eq "VIDEO_CARDS" "$MODE_MESSAGE" "read-only VIDEO_CARDS shows an explanation"

# The final confirmation must show consistency warnings and use an explicit
# "Continue anyway" label when the configuration is suspicious.
UI_MODAL_TITLE=""
UI_MODAL_BODY=""
UI_MODAL_CONFIRM=""
ui_modal_confirm() {
    UI_MODAL_TITLE=$1
    UI_MODAL_BODY=$2
    UI_MODAL_CONFIRM=$4
    return 0
}
config_defaults
state_init
CFG_KERNEL_MODE=manual
CFG_DESKTOP=xfce
CFG_PROFILE=kde
CFG_VIDEO_CARDS=intel
CFG_CREATE_USER=yes
CFG_USERNAME=alice
assert_ok "review confirmation opens with warnings" wizard_confirm_installation
assert_contains "$UI_MODAL_BODY" "Configuration warnings" \
    "review confirmation includes the warnings heading"
assert_contains "$UI_MODAL_BODY" "KDE" "review confirmation includes the profile warning"
assert_eq "Continue anyway" "$UI_MODAL_CONFIRM" \
    "warnings require an explicit continue label"

finish_tests
