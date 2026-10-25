#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"
source "${GI_TEST_ROOT}/lib/disks.sh"

config_defaults
CFG_BOOT_MODE=uefi
CFG_SWAP_MODE=auto
CFG_HOME_MODE=no
assert_ok "UEFI plan" disk_plan_build uefi 102400
assert_eq "3" "$PLAN_COUNT" "UEFI without /home creates esp, swap and root"
assert_eq "esp" "${PLAN_ROLE[0]}"
assert_eq "swap" "${PLAN_ROLE[1]}"
assert_eq "root" "${PLAN_ROLE[2]}"
assert_eq "vfat" "${PLAN_FSTYPE[0]}"
assert_eq "/efi" "${PLAN_MOUNT[0]}"
assert_eq "102399" "${PLAN_END[2]}" "last partition leaves one MiB"
assert_eq "102400" "$PLAN_TOTAL_MIB"

CFG_BOOT_MODE=bios
CFG_BOOT_FS=ext4
CFG_SWAP_MODE=none
assert_ok "BIOS plan without swap" disk_plan_build bios 51200
assert_eq "2" "$PLAN_COUNT"
assert_eq "boot" "${PLAN_ROLE[0]}"
assert_eq "ext4" "${PLAN_FSTYPE[0]}"
assert_eq "/boot" "${PLAN_MOUNT[0]}"
assert_eq "root" "${PLAN_ROLE[1]}"

CFG_BOOT_MODE=uefi
CFG_SWAP_MODE=custom
CFG_SWAP_MIB=4096
CFG_HOME_MODE=separate
CFG_HOME_MIB=20480
CFG_HOME_FS=ext4
assert_ok "UEFI plan with custom swap and home" disk_plan_build uefi 102400
assert_eq "4" "$PLAN_COUNT"
assert_eq "swap" "${PLAN_ROLE[1]}"
assert_eq "4096" "${PLAN_SIZE[1]}"
assert_eq "home" "${PLAN_ROLE[3]}"
assert_eq "ext4" "${PLAN_FSTYPE[3]}"
assert_eq "20480" "${PLAN_SIZE[3]}"
assert_eq "102399" "${PLAN_END[3]}"

# Partitions must not overlap.
for ((i = 0; i < PLAN_COUNT; i++)); do
    for ((j = i + 1; j < PLAN_COUNT; j++)); do
        if ((PLAN_START[i] < PLAN_END[j] && PLAN_START[j] < PLAN_END[i])); then
            printf '  FAIL: partitions %d and %d overlap\n' "$i" "$j"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
        TESTS_RUN=$((TESTS_RUN + 1))
    done
done

CFG_HOME_MODE=no
CFG_SWAP_MODE=none
assert_fail "tiny disk rejected" disk_plan_build uefi 2048
[[ -n $PLAN_ERROR ]] || { printf '  FAIL: PLAN_ERROR not set for tiny disk\n'; TESTS_FAILED=$((TESTS_FAILED + 1)); }
TESTS_RUN=$((TESTS_RUN + 1))

# MBR cannot address more than 2 TiB; the boundary itself is still valid.
CFG_HOME_MODE=no
CFG_SWAP_MODE=none
assert_ok "BIOS plan at 2 TiB boundary" disk_plan_build bios 2097152
assert_fail "BIOS disk over 2 TiB rejected" disk_plan_build bios 2097153
assert_contains "$PLAN_ERROR" "2 TiB" "BIOS size error explains the limit"
assert_ok "UEFI disk over 2 TiB accepted" disk_plan_build uefi 2097153

CFG_HOME_MODE=separate
CFG_HOME_MIB=100000
CFG_SWAP_MODE=none
assert_fail "too large /home rejected" disk_plan_build uefi 65536
CFG_HOME_MODE=no

CFG_DISK=/dev/nvme0n1
CFG_BOOT_MODE=uefi
CFG_SWAP_MODE=none
assert_ok "nvme plan" disk_plan_build uefi 65536
assert_eq "/dev/nvme0n1p1" "$(plan_partition_path 0)"
assert_eq "/dev/nvme0n1p2" "$(plan_partition_path 1)"
assert_contains "$(disk_plan_print)" "UEFI + GPT"
assert_contains "$(disk_plan_markdown)" "| Раздел |"

# choose the correct parted filesystem type token
assert_eq "fat32" "$(parted_fs_type vfat)"
assert_eq "linux-swap" "$(parted_fs_type swap)"
assert_eq "xfs" "$(parted_fs_type xfs)"

finish_tests
