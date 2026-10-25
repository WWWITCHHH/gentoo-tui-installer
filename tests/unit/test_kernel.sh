#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"
source "${GI_TEST_ROOT}/lib/kernel.sh"
source "${GI_TEST_ROOT}/lib/bootloader.sh"

CFG_KERNEL_CMDLINE="root=/dev/sda3 quiet root=UUID=deadbeef splash"
assert_eq "quiet splash" "$(kernel_extra_cmdline)" "root= arguments are stripped"

CFG_KERNEL_CMDLINE="  root=PARTUUID=1234   "
assert_eq "" "$(kernel_extra_cmdline)" "cmdline with only root= becomes empty"

CFG_KERNEL_CMDLINE="quiet intel_iommu=on i915.enable_psr=0"
assert_eq "quiet intel_iommu=on i915.enable_psr=0" "$(kernel_extra_cmdline)"

GI_ROOT="${GI_TEST_TMP}/root"
mkdir -p "$GI_ROOT"
CFG_UUID_ROOT="11111111-2222-3333-4444-555555555555"
CFG_KERNEL_CMDLINE="quiet splash"
kernel_write_cmdline
assert_eq "root=UUID=${CFG_UUID_ROOT} ro quiet splash" "$(<"$GI_ROOT/etc/kernel/cmdline")"
assert_not_contains "$(<"$GI_ROOT/etc/kernel/cmdline")" "root=/dev"

kernel_write_dracut_conf
dracut_conf=$(<"$GI_ROOT/etc/dracut.conf.d/99-installer.conf")
assert_contains "$dracut_conf" 'hostonly="no"'
assert_contains "$dracut_conf" 'hostonly_cmdline="no"'

bootloader_write_defaults
grub_defaults=$(<"$GI_ROOT/etc/default/grub")
assert_contains "$grub_defaults" "GRUB_CMDLINE_LINUX='quiet splash'"
assert_not_contains "$grub_defaults" "root=" "GRUB defaults do not duplicate root="

CFG_KERNEL_CMDLINE="quiet foo'bar"
bootloader_write_defaults
grub_defaults=$(<"$GI_ROOT/etc/default/grub")
assert_contains "$grub_defaults" "GRUB_CMDLINE_LINUX='quiet foo'\\''bar'" \
    "GRUB defaults quote single quotes safely"

finish_tests
