# shellcheck shell=bash
# Live environment checks.

PREFLIGHT_LINES=()
PREFLIGHT_FAILED=0
PREFLIGHT_WARNED=0

preflight_line() {
    local level=$1 message
    message=$(i18n_text "$2")
    PREFLIGHT_LINES+=("${level}|${message}")
    case "$level" in
        fail) PREFLIGHT_FAILED=1 ;;
        warn) PREFLIGHT_WARNED=1 ;;
    esac
    log_info "preflight ${level}: ${message}"
}

preflight_required_commands() {
    local cmd missing=()
    local commands=(
        awk blkid blockdev chroot curl cut df env find findmnt flock fold grep lsblk
        mkfs.ext4 mkfs.vfat mkswap mount mountpoint od parted partprobe readlink
        sed sha256sum sort stat swapon swapoff tar tee udevadm umount wc wipefs
        xargs xz
    )
    for cmd in "${commands[@]}"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        preflight_line fail "$(T 'Missing required commands: %s' "${missing[*]}")"
    else
        preflight_line ok "Required Minimal CD utilities are available"
    fi

    local fs need_xfs=0 need_btrfs=0
    local -a filesystems=("$CFG_ROOT_FS")
    [[ $CFG_HOME_MODE == separate ]] && filesystems+=("$CFG_HOME_FS")
    [[ $CFG_BOOT_MODE == bios ]] && filesystems+=("$CFG_BOOT_FS")
    for fs in "${filesystems[@]}"; do
        case "$fs" in
            xfs) need_xfs=1 ;;
            btrfs) need_btrfs=1 ;;
        esac
    done
    if command_exists mkfs.xfs; then
        preflight_line ok "xfsprogs is available"
    elif ((need_xfs)); then
        preflight_line fail "XFS is selected, but mkfs.xfs was not found"
    else
        preflight_line warn "mkfs.xfs was not found; XFS will be unavailable"
    fi
    if command_exists mkfs.btrfs; then
        preflight_line ok "btrfs-progs is available"
    elif ((need_btrfs)); then
        preflight_line fail "Btrfs is selected, but mkfs.btrfs was not found"
    else
        preflight_line warn "mkfs.btrfs was not found; Btrfs will be unavailable"
    fi
    if command_exists gpg; then
        if [[ -f /usr/share/openpgp-keys/gentoo-release.asc ]]; then
            preflight_line ok "GPG and the Gentoo release key are available"
        else
            preflight_line warn "GPG is available, but the Gentoo release key was not found; only SHA256 will be verified"
        fi
    else
        preflight_line warn "GPG was not found; only SHA256 will be verified"
    fi
}

preflight_network() {
    local url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"
    local desktop_pending=0
    if desktop_is_enabled && ! state_is_done desktop; then
        desktop_pending=1
    fi
    if command_exists curl && curl -fsIL --max-time 12 "$url" >/dev/null 2>&1; then
        preflight_line ok "Network access to distfiles.gentoo.org works"
    elif state_is_done stage3 && state_is_done portage && state_is_done kernel &&
        state_is_done tools && state_is_done bootloader && ((!desktop_pending)); then
        preflight_line warn "The network is unavailable, but all steps that require package downloads are complete"
    else
        preflight_line fail "Cannot reach distfiles.gentoo.org; check the Minimal CD network"
    fi
}

preflight_clock() {
    local epoch year
    epoch=$(date +%s)
    year=$(date +%Y)
    if ((epoch < 1704067200)); then
        preflight_line fail "$(T 'The system clock is wrong (%s); synchronize the time' "$year")"
    elif ((epoch > 2208988800)); then
        preflight_line warn "$(T 'The system clock looks suspicious (%s)' "$year")"
    else
        preflight_line ok "$(T 'System date: %s' "$(date -u '+%Y-%m-%d %H:%M UTC')")"
    fi
}

preflight_secure_boot() {
    local file state=""
    if [[ ! -d /sys/firmware/efi ]]; then
        return 0
    fi
    file=$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' -print -quit 2>/dev/null || true)
    if [[ -n $file ]]; then
        state=$(od -An -t u1 -- "$file" 2>/dev/null | awk '{print $NF; exit}')
    fi
    if [[ $state == 1 ]]; then
        preflight_line warn "Secure Boot is enabled. Unsigned GRUB may fail to boot; disable Secure Boot"
    elif [[ $state == 0 ]]; then
        preflight_line ok "Secure Boot is disabled"
    fi
}

preflight_uefi_variables() {
    if [[ -d /sys/firmware/efi ]]; then
        if [[ -d /sys/firmware/efi/efivars ]]; then
            preflight_line ok "UEFI mode, efivars are available"
        else
            preflight_line fail "UEFI mode, but efivars are not mounted"
        fi
    else
        preflight_line ok "BIOS/Legacy mode"
    fi
}

preflight_disks() {
    local disks=("$@")
    if ((${#disks[@]} == 0)); then
        preflight_line fail "No whole disks were found"
        return
    fi
    if [[ -z $CFG_DISK ]]; then
        preflight_line warn "$(T 'Disks found: %s; no target disk has been selected yet' "${#disks[@]}")"
        return
    fi
    if validate_disk_device "$CFG_DISK" 2>/dev/null; then
        preflight_line ok "$(T 'Disks found: %s; selected %s' "${#disks[@]}" "$CFG_DISK")"
    else
        preflight_line warn "$(T 'The saved disk %s was not found; select a disk in the settings' "$CFG_DISK")"
    fi
}

preflight_workdir() {
    if [[ -w $GI_WORKDIR ]]; then
        preflight_line ok "$(T 'Working directory: %s' "$GI_WORKDIR")"
    else
        preflight_line fail "$(T 'Working directory is not writable: %s' "$GI_WORKDIR")"
    fi
}

preflight_collect() {
    PREFLIGHT_LINES=()
    PREFLIGHT_FAILED=0
    PREFLIGHT_WARNED=0

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        preflight_line ok "Running as root"
    else
        preflight_line fail "The script is not running as root"
    fi
    if [[ $(uname -m) == x86_64 ]]; then
        preflight_line ok "Architecture: x86_64 (amd64)"
    else
        preflight_line fail "$(T 'Only amd64/x86_64 is supported; found: %s' "$(uname -m)")"
    fi
    preflight_uefi_variables
    preflight_required_commands
    preflight_clock
    preflight_network
    preflight_secure_boot
    preflight_workdir

    local -a disks=()
    mapfile -t disks < <(discover_disks 2>/dev/null || true)
    preflight_disks "${disks[@]}"
    if [[ -n $CFG_DISK && -b $CFG_DISK ]]; then
        local removable=0
        [[ -r /sys/block/${CFG_DISK##*/}/removable ]] &&
            read -r removable <"/sys/block/${CFG_DISK##*/}/removable" || true
        if [[ $removable == 1 ]]; then
            preflight_line warn "$(T 'The target disk %s looks removable. Make sure it is not the installation media' "$CFG_DISK")"
        fi
    fi
}

preflight_render() {
    local entry level message symbol color
    ui_header "Environment check" "The installer checks the Minimal CD before changing the disk"
    for entry in "${PREFLIGHT_LINES[@]}"; do
        IFS='|' read -r level message <<<"$entry"
        case "$level" in
            ok) symbol="✓"; color=$C_GREEN ;;
            warn) symbol="!"; color=$C_YELLOW ;;
            fail) symbol="✖"; color=$C_RED ;;
        esac
        printf '  %s%s%s %s\n' "$color" "$symbol" "$C_RESET" "$message"
    done
    printf '\n'
    if ((PREFLIGHT_FAILED)); then
        ui_footer "Critical problems found. Enter - exit"
        ui_read_key || true
        return 1
    fi
    ui_footer "Enter - continue · Esc - exit"
    if ! ui_read_key; then
        return 1
    fi
    [[ $UI_KEY != esc ]]
}

preflight_run() {
    preflight_collect
    if ((PREFLIGHT_FAILED)); then
        if ((GI_UNATTENDED || (GI_ASSUME_YES && !GI_INSTALL_CONFIRMED))); then
            log_error "preflight failed before an unattended installation"
            return 1
        fi
        # Show the report so the user can see which checks are marked red.
        preflight_render || true
        return 1
    fi
    if ((GI_ASSUME_YES || GI_UNATTENDED || GI_INSTALL_CONFIRMED)); then
        return 0
    fi
    preflight_render || return 1
    return 0
}

preflight_install_media_warning() {
    local body
    body=$(T 'This installer CREATES AND DELETES PARTITIONS AND FILESYSTEMS.\n\nA data backup is mandatory. The installer does not support\nencryption, LVM, RAID or automatic dual-boot configuration.\n\nSupported Gentoo Handbook scenarios:\n  • UEFI + GPT, GRUB bootloader (ESP at /efi)\n  • BIOS + MBR, GRUB bootloader (/boot)\n\nSteps: check -> disk -> Stage3 -> Portage -> kernel -> system\n-> services -> bootloader -> desktop environment -> finish.\n\nContinue only if you understand the consequences.')
    ui_header "Important"
    ui_wrap "$body"
    ui_footer "Enter - accept and continue · Esc - exit"
    ui_read_key || return 1
    [[ $UI_KEY != esc ]]
}
