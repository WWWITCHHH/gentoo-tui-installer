#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"

assert_eq "512 MiB" "$(human_mib 512)"
assert_eq "2 GiB" "$(human_mib 2048)"
assert_eq "1 TiB" "$(human_mib 1048576)"

assert_eq "/dev/sda2" "$(part_path /dev/sda 2)"
assert_eq "/dev/nvme0n1p1" "$(part_path /dev/nvme0n1 1)"
assert_eq "/dev/mmcblk0p3" "$(part_path /dev/mmcblk0 3)"

assert_eq "'a'\\''b'" "$(shell_quote "a'b")"

rendered=$(render_cmd printf '%s' 'a b')
assert_contains "$rendered" "printf" "render_cmd includes command"
assert_contains "$rendered" "a\\ b" "render_cmd quotes spaces"

config_defaults
assert_eq "xfs" "$CFG_ROOT_FS"
assert_eq "xfs" "$CFG_HOME_FS"
assert_eq "openrc" "$CFG_STAGE_FLAVOR"
assert_eq "none" "$CFG_DESKTOP"
config_derived
assert_eq "openrc" "$CFG_INIT"
CFG_STAGE_FLAVOR=desktop-systemd
config_derived
assert_eq "systemd" "$CFG_INIT"
assert_eq "desktop" "$CFG_PROFILE"

# config_derived must not overwrite an explicit non-default profile.
CFG_PROFILE=gnome
CFG_STAGE_FLAVOR=desktop-openrc
config_derived
assert_eq "gnome" "$CFG_PROFILE" "desktop stage keeps selected profile"

# Desktop environment selection adjusts only a generic profile.
config_defaults
CFG_DESKTOP=xfce
config_derived
assert_eq "desktop" "$CFG_PROFILE" "XFCE selects the desktop profile"
CFG_DESKTOP=gnome
CFG_PROFILE=stage
config_derived
assert_eq "gnome" "$CFG_PROFILE" "GNOME selects the GNOME profile"
CFG_DESKTOP=gnome
CFG_PROFILE=desktop
config_derived
assert_eq "gnome" "$CFG_PROFILE" "GNOME replaces the generic desktop profile"
CFG_DESKTOP=xfce
CFG_PROFILE=kde
config_derived
assert_eq "kde" "$CFG_PROFILE" "XFCE preserves an explicit KDE profile"
CFG_DESKTOP=gnome
CFG_PROFILE=hardened
config_derived
assert_eq "hardened" "$CFG_PROFILE" "GNOME preserves an explicit hardened profile"
CFG_DESKTOP=none
CFG_PROFILE=gnome
config_derived
assert_eq "gnome" "$CFG_PROFILE" "no desktop keeps an explicit GNOME profile"

# A graphical install upgrades the base Stage3 to the matching desktop Stage3.
CFG_DESKTOP=xfce
CFG_STAGE_FLAVOR=openrc
CFG_PROFILE=stage
config_derived
assert_eq "desktop-openrc" "$CFG_STAGE_FLAVOR" "XFCE upgrades OpenRC to the desktop Stage3"
assert_eq "openrc" "$CFG_INIT" "desktop Stage3 keeps the selected init system"
assert_eq "desktop" "$CFG_PROFILE" "XFCE selects the desktop profile"
CFG_STAGE_FLAVOR=systemd
config_derived
assert_eq "desktop-systemd" "$CFG_STAGE_FLAVOR" "XFCE upgrades systemd to the desktop Stage3"
assert_eq "systemd" "$CFG_INIT" "desktop systemd keeps systemd"

# An explicitly selected desktop Stage3 is not downgraded when no desktop is used.
CFG_DESKTOP=none
CFG_STAGE_FLAVOR=desktop-openrc
CFG_PROFILE=stage
config_derived
assert_eq "desktop-openrc" "$CFG_STAGE_FLAVOR" "desktop Stage3 is preserved without a desktop"
assert_eq "desktop" "$CFG_PROFILE" "desktop Stage3 still selects the desktop profile"

# GPU detection maps the common PCI vendors to VIDEO_CARDS values.
drm_root=$(mktemp -d "${TMPDIR:-/tmp}/gi-drm.XXXXXX")
make_drm_card() {
    local vendor=$1 device=$2
    rm -rf -- "$drm_root/card0"
    mkdir -p "$drm_root/card0/device"
    printf '%s\n' "$vendor" >"$drm_root/card0/device/vendor"
    printf '%s\n' "$device" >"$drm_root/card0/device/device"
}
make_drm_card 0x8086 0x1234
assert_eq "intel" "$(GI_DRM_CLASS_DIR=$drm_root hardware_detect_video_cards)" "Intel GPU"
make_drm_card 0x1002 0x73ff
assert_eq "amdgpu radeonsi" "$(GI_DRM_CLASS_DIR=$drm_root hardware_detect_video_cards)" "AMD GPU"
make_drm_card 0x10de 0x1f02
assert_eq "nouveau" "$(GI_DRM_CLASS_DIR=$drm_root hardware_detect_video_cards)" "NVIDIA GPU"
make_drm_card 0x15ad 0x0405
assert_eq "vmware" "$(GI_DRM_CLASS_DIR=$drm_root hardware_detect_video_cards)" "VMware GPU"
make_drm_card 0x1234 0x1111
assert_eq "qxl" "$(GI_DRM_CLASS_DIR=$drm_root hardware_detect_video_cards)" "QEMU QXL GPU"
make_drm_card 0x1af4 0x1050
assert_eq "virgl" "$(GI_DRM_CLASS_DIR=$drm_root hardware_detect_video_cards)" "virtio GPU"
rm -rf -- "$drm_root"

expected_steps=(disk stage3 portage kernel system tools bootloader desktop finalize)
assert_eq "${expected_steps[*]}" "${STATE_STEPS[*]}" "state step order includes desktop"
assert_eq "$GI_STEP_TOTAL" "${#STATE_STEPS[@]}" "step total matches state steps"

# Non-custom swap ignores a stale size but keeps auto-captured device fields.
config_defaults
CFG_SWAP_MODE=auto
CFG_SWAP_MIB=8192
CFG_PART_SWAP=/dev/sda2
CFG_UUID_SWAP=deadbeef
config_derived
assert_eq "0" "$CFG_SWAP_MIB" "auto swap ignores stale size"
assert_eq "/dev/sda2" "$CFG_PART_SWAP" "auto swap keeps captured partition"

CFG_SWAP_MODE=none
CFG_FORMAT_SWAP=yes
config_derived
assert_eq "" "$CFG_PART_SWAP" "swap none clears partition"
assert_eq "" "$CFG_UUID_SWAP" "swap none clears UUID"
assert_eq "no" "$CFG_FORMAT_SWAP" "swap none disables formatting"

CFG_SWAP_MODE=custom
CFG_SWAP_MIB=4096
config_derived
assert_eq "4096" "$CFG_SWAP_MIB" "custom swap keeps size"

# Layout switches discard partitions and UUIDs from the other boot mode.
config_defaults
CFG_BOOT_MODE=uefi
CFG_PART_BOOT=/dev/sda1
CFG_UUID_BOOT=beef
CFG_PART_ESP=/dev/sda2
CFG_UUID_ESP=cafe
config_derived
assert_eq "" "$CFG_PART_BOOT" "UEFI clears BIOS boot partition"
assert_eq "" "$CFG_UUID_BOOT" "UEFI clears BIOS boot UUID"
assert_eq "/dev/sda2" "$CFG_PART_ESP"
assert_eq "cafe" "$CFG_UUID_ESP"

CFG_BOOT_MODE=bios
CFG_PART_ESP=/dev/sda2
CFG_UUID_ESP=cafe
config_derived
assert_eq "" "$CFG_PART_ESP" "BIOS clears ESP partition"
assert_eq "" "$CFG_UUID_ESP" "BIOS clears ESP UUID"

CFG_HOME_MODE=no
CFG_PART_HOME=/dev/sda4
CFG_UUID_HOME=abcd
CFG_FORMAT_HOME=yes
config_derived
assert_eq "" "$CFG_PART_HOME" "home none clears partition"
assert_eq "" "$CFG_UUID_HOME" "home none clears UUID"
assert_eq "no" "$CFG_FORMAT_HOME" "home none disables formatting"

config_defaults
CFG_HOSTNAME='a "b" \ c'
CFG_STAGE_URL='https://example.invalid/stage3.tar.xz'
mkdir -p "$GI_WORKDIR"
config_save
CFG_HOSTNAME=""
CFG_STAGE_URL=""
config_load "$GI_CONFIG_FILE"
assert_eq 'a "b" \ c' "$CFG_HOSTNAME" "config roundtrip keeps quotes and backslashes"
assert_eq 'https://example.invalid/stage3.tar.xz' "$CFG_STAGE_URL"

cat >"$GI_WORKDIR/comments.conf" <<'EOF'
# Leading comment.
SCHEMA="1"

   # Indented comment.
HOSTNAME="inline"        # trailing comment with "quotes" and # hash
KERNEL_CMDLINE="quiet # not a comment"   # real comment
EOF
config_defaults
config_load "$GI_WORKDIR/comments.conf"
assert_eq "inline" "$CFG_HOSTNAME" "config_load strips trailing comments"
assert_eq "quiet # not a comment" "$CFG_KERNEL_CMDLINE" "config_load keeps hashes inside values"

printf 'HOSTNAME=unquoted\nSCHEMA="1"\n' >"$GI_WORKDIR/unquoted.conf"
assert_fail_isolated "config_load rejects unquoted values" config_load "$GI_WORKDIR/unquoted.conf"
printf 'SCHEMA="1" junk\n' >"$GI_WORKDIR/junk.conf"
assert_fail_isolated "config_load rejects text after the value" config_load "$GI_WORKDIR/junk.conf"

assert_ok "known config key" config_key_valid HOSTNAME
assert_fail "unknown config key" config_key_valid PASSWORD

state_init
assert_eq "0" "${STATE_DONE[disk]}"
state_mark_done disk
state_mark_done stage3
assert_eq "1" "${STATE_DONE[disk]}"
state_load
assert_eq "1" "${STATE_DONE[disk]}" "state_load keeps done steps"
assert_eq "0" "${STATE_DONE[portage]}" "state_load defaults missing steps to zero"
state_reset
assert_eq "0" "${STATE_DONE[disk]}"
[[ ! -f $GI_STATE_FILE ]] || { printf '  FAIL: state file was not removed\n'; TESTS_FAILED=$((TESTS_FAILED + 1)); }

jobs=$(make_jobs_suggestion)
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { printf '  FAIL: make_jobs_suggestion returned %s\n' "$jobs"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
TESTS_RUN=$((TESTS_RUN + 1))

finish_tests
