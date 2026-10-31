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

# Automatic kernel configuration generated from the target settings.
config_defaults
CFG_BOOT_MODE=uefi
CFG_INIT=systemd
CFG_ROOT_FS=ext4
CFG_VIDEO_CARDS="vmware intel"
auto_options=$(kernel_auto_config_options)
assert_contains "$auto_options" "CONFIG_EXT4_FS y" "automatic config enables ext4"
assert_contains "$auto_options" "CONFIG_XFS_FS y" "automatic config enables xfs"
assert_contains "$auto_options" "CONFIG_VIRTIO_BLK y" "automatic config enables virtio block"
assert_contains "$auto_options" "CONFIG_DEVTMPFS_MOUNT y" "automatic config enables devtmpfs mount"
assert_contains "$auto_options" "CONFIG_EFI_STUB y" "automatic config enables the EFI stub"
assert_contains "$auto_options" "CONFIG_CGROUPS y" "automatic config enables systemd cgroups"
assert_contains "$auto_options" "CONFIG_DRM_VMWGFX m" "automatic config includes VMware graphics"
assert_contains "$auto_options" "CONFIG_DRM_I915 m" "automatic config includes Intel graphics"

CFG_VIDEO_CARDS=nvidia
auto_nvidia=$(kernel_auto_config_options)
assert_contains "$auto_nvidia" "CONFIG_DRM_NOUVEAU n" "proprietary NVIDIA disables nouveau"

auto_required=$(kernel_auto_required_symbols)
assert_contains "$auto_required" "CONFIG_EXT4_FS" "required symbols include ext4"
assert_contains "$auto_required" "CONFIG_EFI_STUB" "required symbols include the EFI stub"
assert_contains "$auto_required" "CONFIG_CGROUPS" "required symbols include cgroups"

CFG_BOOT_MODE=bios
CFG_INIT=openrc
CFG_VIDEO_CARDS=""
auto_bios=$(kernel_auto_config_options)
assert_contains "$auto_bios" "CONFIG_VGA_CONSOLE y" "BIOS automatic config enables VGA console"
assert_contains "$auto_bios" "CONFIG_DRM_SIMPLEDRM y" "automatic config keeps a simple framebuffer"
auto_bios_required=$(kernel_auto_required_symbols)
assert_contains "$auto_bios_required" "CONFIG_VGA_CONSOLE" "BIOS required symbols include VGA console"
assert_not_contains "$auto_bios_required" "CONFIG_EFI_STUB" "BIOS required symbols omit the EFI stub"

finish_tests
