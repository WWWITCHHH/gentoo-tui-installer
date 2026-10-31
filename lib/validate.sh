# shellcheck shell=bash
# Input and configuration validators.

VALIDATION_MESSAGE=""
CONFIG_WARNINGS=()

fail_validation() {
    VALIDATION_MESSAGE=$*
    return 1
}

validation_error() {
    local message
    message=$(i18n_text "$*")
    VALIDATION_ERRORS+=("$message")
    log_warn "validation: $message"
}

validate_hostname() {
    local name=$1
    [[ -n $name ]] || fail_validation "Hostname cannot be empty." || return 1
    ((${#name} <= 253)) || fail_validation "Hostname is longer than 253 characters." || return 1
    [[ $name =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        fail_validation "Use letters, digits, dots and hyphens." || return 1
    [[ $name != *..* ]] || fail_validation "Two consecutive dots are not allowed." || return 1
    return 0
}

validate_username() {
    local name=$1
    [[ $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
        fail_validation "Username: a lowercase letter or _, up to 32 characters." || return 1
    [[ $name != root ]] || fail_validation "The root user already exists." || return 1
    return 0
}

validate_timezone() {
    local zone=$1
    if [[ $zone == UTC ]]; then
        return 0
    fi
    [[ $zone =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)+$ ]] ||
        fail_validation "Timezone must look like Europe/Moscow." || return 1
    [[ $zone != *..* ]] || fail_validation "Invalid timezone." || return 1
    if [[ -e "$GI_ROOT/usr/share/zoneinfo/$zone" || -e "/usr/share/zoneinfo/$zone" ]]; then
        return 0
    fi
    fail_validation "$(T 'Timezone not found in zoneinfo: %s' "$zone")"
    return 1
}

validate_locale() {
    local locale=$1
    [[ $locale =~ ^([a-z]{2,3}_[A-Z]{2}\.UTF-8(@[a-z0-9]+)?|C\.UTF-8)$ ]] ||
        fail_validation "Use a UTF-8 locale, for example ru_RU.UTF-8." || return 1
    return 0
}

validate_language() {
    case "$1" in
        en|ru) return 0 ;;
        *) fail_validation "Language must be en or ru."; return 1 ;;
    esac
}

validate_keymap() {
    local keymap=$1
    [[ $keymap =~ ^[A-Za-z0-9_-]+$ ]] ||
        fail_validation "Keymap: only letters, digits, _ and - are allowed." || return 1
    return 0
}

validate_nonempty() {
    [[ -n ${1:-} ]] || fail_validation "Value cannot be empty." || return 1
    return 0
}

validate_mib() {
    local value=$1
    [[ $value =~ ^[0-9]+$ ]] || fail_validation "Enter an integer number of MiB." || return 1
    ((value > 0)) || fail_validation "Size must be greater than zero." || return 1
    return 0
}

validate_int_range() {
    local value=$1 min=$2 max=$3
    [[ $value =~ ^[0-9]+$ ]] || fail_validation "Enter an integer." || return 1
    ((value >= min && value <= max)) || fail_validation "$(T 'Allowed range: %s..%s.' "$min" "$max")" || return 1
    return 0
}

validate_url() {
    local url=$1
    [[ $url =~ ^https?://[^[:space:]]+$ ]] ||
        fail_validation "URL must start with http:// or https://." || return 1
    return 0
}

validate_optional_url() {
    [[ -z ${1:-} ]] && return 0
    validate_url "$1"
}

validate_disk_device() {
    local disk=$1
    [[ $disk == /dev/* ]] || fail_validation "Specify a block device under /dev." || return 1
    [[ -b $disk ]] || fail_validation "$(T 'Device not found: %s' "$disk")" || return 1
    [[ $(lsblk -dno TYPE -- "$disk" 2>/dev/null) == disk ]] ||
        fail_validation "$(T 'Not a whole disk: %s' "$disk")" || return 1
    return 0
}

validate_root_fs() {
    case "$1" in
        xfs|ext4|btrfs) return 0 ;;
        *) fail_validation "Supported filesystems: xfs, ext4 and btrfs."; return 1 ;;
    esac
}

validate_bool() {
    case "$1" in
        yes|no) return 0 ;;
        *) fail_validation "Expected yes or no."; return 1 ;;
    esac
}

validate_desktop() {
    case "$1" in
        none|xfce|gnome) return 0 ;;
        *) fail_validation "Desktop: none, xfce or gnome."; return 1 ;;
    esac
}

validate_no_control() {
    local value=$1
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *'"'* ]] ||
        fail_validation "Value contains invalid characters." || return 1
    return 0
}

validate_use_flags() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9_@+.-]*(\ [A-Za-z0-9_@+.-]+)*$ ]] ||
        fail_validation "USE flags: space-separated, without quotes or special characters." || return 1
    return 0
}

validate_optional_tokens() {
    [[ -z ${1:-} ]] && return 0
    validate_use_flags "$1"
}

validate_kernel_cmdline() {
    local value=$1
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *'"'* ]] ||
        fail_validation "Kernel command line contains invalid characters." || return 1
    # /etc/default/grub is sourced as a shell script. Reject characters that
    # could expand there even though the value is also single-quoted.
    [[ $value != *'$'* && $value != *'`'* && $value != *'\'* ]] ||
        fail_validation 'Kernel command line must not contain $, ` or \' || return 1
    return 0
}

validate_cflags() {
    local value=$1
    [[ -n $value ]] || fail_validation "CFLAGS cannot be empty." || return 1
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *'"'* ]] ||
        fail_validation "CFLAGS contains invalid characters." || return 1
    return 0
}

# Suggests swap in MiB using the table from the Gentoo Handbook, assuming no
# hibernation. The user can override the value.
suggest_swap_mib() {
    local ram_mib
    ram_mib=$(awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || true)
    ram_mib=${ram_mib:-4096}
    if ((ram_mib <= 2048)); then
        printf '4096'
    elif ((ram_mib <= 8192)); then
        printf '%d' "$ram_mib"
    else
        printf '8192'
    fi
}

make_jobs_suggestion() {
    local cpus ram_mib by_ram jobs
    cpus=$(nproc 2>/dev/null || printf '1')
    ram_mib=$(awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || printf '2048')
    by_ram=$((ram_mib / 2048))
    ((by_ram < 1)) && by_ram=1
    jobs=$cpus
    ((by_ram < jobs)) && jobs=$by_ram
    ((jobs < 1)) && jobs=1
    printf '%d' "$jobs"
}

config_validate() {
    VALIDATION_ERRORS=()
    local flag disk_mib

    validate_language "$CFG_UI_LANGUAGE" 2>/dev/null ||
        validation_error "UI language: en or ru."

    [[ $CFG_BOOT_MODE == uefi || $CFG_BOOT_MODE == bios ]] ||
        validation_error "Boot mode: uefi or bios."
    if [[ $CFG_BOOT_MODE == uefi && ! -d /sys/firmware/efi ]]; then
        validation_error "UEFI is selected, but the Minimal CD booted in BIOS mode. Reboot the CD in UEFI mode."
    fi
    if [[ $CFG_BOOT_MODE == bios && -d /sys/firmware/efi ]]; then
        validation_error "BIOS is selected, but the Minimal CD booted in UEFI mode."
    fi

    [[ $CFG_DISK_MODE == auto || $CFG_DISK_MODE == manual ]] ||
        validation_error "Disk mode: auto or manual."

    if [[ $CFG_DISK_MODE == auto ]]; then
        if ! validate_disk_device "$CFG_DISK" 2>/dev/null; then
            validation_error "No valid target disk is selected."
        else
            disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
            if ((disk_mib < 16384)); then
                validation_error "The disk is smaller than 16 GiB; a Gentoo installation may not fit."
            fi
            if [[ $CFG_BOOT_MODE == bios ]] && ((disk_mib > 2097152)); then
                validation_error "BIOS + MBR does not support disks larger than 2 TiB; use UEFI + GPT."
            fi
            if ! disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" >/dev/null 2>&1; then
                validation_error "$(T 'Not enough space for the selected layout: %s.' "${PLAN_ERROR:-plan error}")"
            fi
            if [[ $CFG_HOME_MODE == separate ]]; then
                validate_mib "$CFG_HOME_MIB" 2>/dev/null ||
                    validation_error "The /home size must be an integer number of MiB."
            fi
        fi
    else
        validate_disk_device "$CFG_DISK" 2>/dev/null ||
            validation_error "No valid disk is selected for the manual layout."
        [[ -n $CFG_PART_ROOT && -b $CFG_PART_ROOT ]] ||
            validation_error "No root partition is selected for the manual layout."
        if [[ $CFG_BOOT_MODE == uefi ]]; then
            [[ -n $CFG_PART_ESP && -b $CFG_PART_ESP ]] ||
                validation_error "No ESP is selected for UEFI."
        else
            [[ -n $CFG_PART_BOOT && -b $CFG_PART_BOOT ]] ||
                validation_error "No /boot partition is selected for BIOS."
        fi
        if [[ -n $CFG_PART_HOME && -b $CFG_PART_HOME ]]; then
            :
        elif [[ $CFG_HOME_MODE == separate ]]; then
            validation_error "No /home partition is selected."
        fi
        if [[ -b $CFG_DISK ]] && [[ $CFG_BOOT_MODE == bios ]]; then
            disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
            if ((disk_mib > 2097152)); then
                validation_error "BIOS + MBR does not support disks larger than 2 TiB; use UEFI + GPT."
            fi
        fi
        local -A seen_parts=()
        local part parent="" current_parent
        for part in "$CFG_PART_ROOT" "$CFG_PART_ESP" "$CFG_PART_BOOT" \
            "$CFG_PART_SWAP" "$CFG_PART_HOME"; do
            [[ -n $part ]] || continue
            if [[ -n ${seen_parts[$part]+set} ]]; then
                validation_error "$(T 'Partition %s is assigned to more than one role.' "$part")"
            else
                seen_parts[$part]=1
            fi
            [[ -b $part ]] || continue
            current_parent=$(lsblk -no PKNAME -- "$part" 2>/dev/null | head -n 1)
            [[ -n $current_parent ]] || continue
            if [[ -z $parent ]]; then
                parent=$current_parent
            elif [[ $parent != "$current_parent" ]]; then
                validation_error "All manual-layout partitions must be on the same disk."
                break
            fi
        done
        if [[ -n $parent && -n $CFG_DISK && ${CFG_DISK##*/} != "$parent" ]]; then
            validation_error "$(T 'The partitions belong to /dev/%s, but the selected disk is %s.' "$parent" "$CFG_DISK")"
        fi
    fi

    validate_root_fs "$CFG_ROOT_FS" 2>/dev/null ||
        validation_error "Root filesystem: xfs, ext4 or btrfs."
    validate_root_fs "$CFG_HOME_FS" 2>/dev/null ||
        validation_error "Filesystem for /home: xfs, ext4 or btrfs."
    if [[ $CFG_BOOT_MODE == bios ]]; then
        validate_root_fs "$CFG_BOOT_FS" 2>/dev/null ||
            validation_error "Filesystem for /boot: xfs, ext4 or btrfs."
    fi
    case "$CFG_SWAP_MODE" in
        auto|none) ;;
        custom)
            validate_mib "$CFG_SWAP_MIB" 2>/dev/null ||
                validation_error "Custom swap size must be greater than zero."
            ;;
        *) validation_error "Swap mode: auto, none or custom." ;;
    esac
    [[ $CFG_HOME_MODE == no || $CFG_HOME_MODE == separate ]] ||
        validation_error "/home mode: no or separate."

    case "$CFG_STAGE_FLAVOR" in
        openrc|systemd|desktop-openrc|desktop-systemd) ;;
        *) validation_error "Unknown Stage3 variant." ;;
    esac
    validate_url "$CFG_MIRROR" 2>/dev/null ||
        validation_error "Invalid mirror URL."
    if [[ -n $CFG_STAGE_URL ]]; then
        validate_url "$CFG_STAGE_URL" 2>/dev/null ||
            validation_error "Invalid Stage3 URL."
    fi

    case "$CFG_PROFILE" in
        stage|desktop|gnome|kde|hardened) ;;
        *) validation_error "Unknown Portage profile." ;;
    esac
    validate_desktop "$CFG_DESKTOP" 2>/dev/null ||
        validation_error "$(T 'Desktop: %s.' "${VALIDATION_MESSAGE:-invalid}")"

    case "$CFG_KERNEL_MODE" in
        bin|dist|manual) ;;
        *) validation_error "Unknown kernel installation method." ;;
    esac

    case "$CFG_MICROCODE" in
        auto|none|intel|amd) ;;
        *) validation_error "Microcode: auto, none, intel or amd." ;;
    esac

    [[ $CFG_BOOTLOADER == grub ]] ||
        validation_error "This version supports GRUB only."

    validate_hostname "$CFG_HOSTNAME" 2>/dev/null ||
        validation_error "$(T 'Hostname: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    validate_timezone "$CFG_TIMEZONE" 2>/dev/null ||
        validation_error "$(T 'Timezone: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    validate_locale "$CFG_LOCALE" 2>/dev/null ||
        validation_error "$(T 'Locale: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    validate_keymap "$CFG_KEYMAP" 2>/dev/null ||
        validation_error "$(T 'Keymap: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    case "$CFG_NETWORK" in
        dhcpcd|networkmanager|none) ;;
        *) validation_error "Unknown network configuration method." ;;
    esac
    case "$CFG_HWCLOCK" in
        UTC|local) ;;
        *) validation_error "Hardware clock: UTC or local." ;;
    esac
    if [[ $CFG_CREATE_USER == yes ]]; then
        validate_username "$CFG_USERNAME" 2>/dev/null ||
            validation_error "$(T 'Username: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    fi
    validate_cflags "$CFG_CFLAGS" 2>/dev/null ||
        validation_error "$(T 'CFLAGS: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    validate_use_flags "$CFG_USE_EXTRA" 2>/dev/null ||
        validation_error "$(T 'USE: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    validate_optional_tokens "$CFG_VIDEO_CARDS" 2>/dev/null ||
        validation_error "$(T 'VIDEO_CARDS: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    validate_kernel_cmdline "$CFG_KERNEL_CMDLINE" 2>/dev/null ||
        validation_error "$(T 'Kernel cmdline: %s.' "${VALIDATION_MESSAGE:-invalid}")"

    for flag in CFG_FIRMWARE CFG_CPU_FLAGS CFG_UPDATE_WORLD CFG_SSH CFG_CRON \
        CFG_CHRONY CFG_SYSLOG CFG_SUDO CFG_CREATE_USER CFG_FORMAT_ESP \
        CFG_FORMAT_BOOT CFG_FORMAT_SWAP CFG_FORMAT_ROOT CFG_FORMAT_HOME; do
        validate_bool "${!flag}" 2>/dev/null ||
            validation_error "$(T '%s: %s.' "$flag" "${VALIDATION_MESSAGE:-expected yes/no}")"
    done

    if [[ $CFG_MAKE_JOBS != auto ]]; then
        validate_int_range "$CFG_MAKE_JOBS" 1 256 2>/dev/null ||
            validation_error "$(T 'MAKEOPTS: %s.' "${VALIDATION_MESSAGE:-invalid}")"
    fi

    ((${#VALIDATION_ERRORS[@]} == 0))
}

# Non-fatal configuration checks. These combinations are valid enough to start
# the installer, but they are likely to surprise the user or require manual
# follow-up, so the review page shows them in an explicit warning before the
# final confirmation. Returns 0 when at least one warning was collected.
config_check_consistency() {
    CONFIG_WARNINGS=()

    if [[ $CFG_DESKTOP == none ]]; then
        case "$CFG_PROFILE" in
            desktop|gnome|kde)
                CONFIG_WARNINGS+=("$(T 'A desktop Portage profile is selected, but no desktop environment is configured.')")
                ;;
        esac
    else
        case "$CFG_PROFILE" in
            gnome)
                if [[ $CFG_DESKTOP != gnome ]]; then
                    CONFIG_WARNINGS+=("$(T 'The GNOME Portage profile is selected, but the desktop environment is %s.' "$CFG_DESKTOP")")
                fi
                ;;
            kde)
                CONFIG_WARNINGS+=("$(T 'The KDE Portage profile is selected, but this installer only configures XFCE or GNOME.')")
                ;;
            hardened)
                CONFIG_WARNINGS+=("$(T 'The hardened profile with a desktop environment may need manual USE adjustments.')")
                ;;
        esac
        if [[ -z $CFG_VIDEO_CARDS ]]; then
            CONFIG_WARNINGS+=("$(T 'No VIDEO_CARDS are set; Xorg may run without acceleration.')")
        fi
        if [[ $CFG_CREATE_USER != yes ]]; then
            CONFIG_WARNINGS+=("$(T 'A desktop environment is selected, but no regular user is created; you will log in as root.')")
        fi
    fi

    if [[ $CFG_NETWORK == none && $CFG_SSH == yes ]]; then
        CONFIG_WARNINGS+=("$(T 'SSH is enabled, but network configuration is set to none.')")
    fi

    if [[ $CFG_KERNEL_MODE == manual ]]; then
        CONFIG_WARNINGS+=("$(T 'Manual kernel configuration remains interactive and requires the correct storage, filesystem and graphics drivers. Choose a binary kernel if unsure.')")
    fi

    ((${#CONFIG_WARNINGS[@]}))
}
