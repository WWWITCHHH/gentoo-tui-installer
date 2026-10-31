# shellcheck shell=bash
# Settings-first configuration wizard.
#
# All settings are collected on a small number of semantically grouped pages.
# The installation starts only after the review page has been confirmed, and
# then runs without waiting for the user between steps.

wizard_save() {
    config_derived
    config_save
}

wizard_bool() {
    local title=$1 question=$2 current=$3 default=yes
    [[ $current == no ]] && default=no
    # The TUI is drawn on stderr so that command substitution captures only the
    # yes/no answer. Without this, ANSI screen output would be stored in CFG_*.
    if ui_confirm "$title" "$question" "$default" 1>&2; then
        printf 'yes'
    else
        printf 'no'
    fi
}

wizard_step_locked() {
    local step=$1 title=$2
    state_is_done "$step" || return 0
    ui_msg "$(T 'Step already completed')" \
        "$(T '%s: this step is already complete, so changes will not be applied.\nTo configure the installation again, reset the state in the main menu.' "$title")"
    return 1
}

wizard_choose_fs() {
    local title=$1 current=$2
    disks_choose_fs "$title" "$current"
}

# Shared field helpers -------------------------------------------------------

# wizard_pick VARIABLE TITLE SUBTITLE CURRENT ITEM...
# Opens a standardized single-choice window and writes the tag to VARIABLE.
wizard_pick() {
    local var=$1 title=$2 subtitle=$3 current=$4
    shift 4
    if ui_choice single "$title" "$subtitle" "$current" "$@"; then
        printf -v "$var" '%s' "$UI_RESULT"
        wizard_save
        return 0
    fi
    return 1
}

wizard_pick_bool() {
    local var=$1 title=$2 subtitle=$3 current=${!1}
    local default=no
    [[ $current == yes ]] && default=yes
    if ui_choice single "$title" "$subtitle" "$default" \
        "yes|$(T 'Yes')|$(T 'Enable this option')" \
        "no|$(T 'No')|$(T 'Disable this option')"; then
        printf -v "$var" '%s' "$UI_RESULT"
        wizard_save
        return 0
    fi
    return 1
}

wizard_prompt() {
    local var=$1 title=$2 prompt=$3 validator=${4:-} hint=${5:-}
    local current=${!var}
    if ui_input "$title" "$prompt" "$current" "$validator" "$hint" no; then
        printf -v "$var" '%s' "$UI_RESULT"
        wizard_save
        return 0
    fi
    return 1
}

wizard_prompt_int() {
    local var=$1 title=$2 prompt=$3 min=$4 max=$5 default=$6
    if ui_int_input "$title" "$prompt" "$default" "$min" "$max"; then
        printf -v "$var" '%s' "$UI_RESULT"
        wizard_save
        return 0
    fi
    return 1
}

wizard_bool_text() {
    [[ $1 == yes ]] && printf 'yes' || printf 'no'
}

wizard_clear_partitions() {
    CFG_PART_ESP="" CFG_PART_BOOT="" CFG_PART_SWAP="" CFG_PART_ROOT="" CFG_PART_HOME=""
    CFG_UUID_ESP="" CFG_UUID_BOOT="" CFG_UUID_SWAP="" CFG_UUID_ROOT="" CFG_UUID_HOME=""
}

# Easy mode applies its defaults only once for a brand-new configuration.
# Existing values (including values created by advanced mode) are preserved.
wizard_apply_mode_defaults() {
    ((GI_MODE_DEFAULTS_APPLIED)) && return 0
    GI_MODE_DEFAULTS_APPLIED=1
    ((GI_EASY_MODE)) || return 0
    ((GI_CONFIG_EXISTED)) && return 0
    CFG_ROOT_FS=ext4
    CFG_STAGE_FLAVOR=systemd
    CFG_UPDATE_WORLD=yes
    config_derived
    config_save
    log_info "easy mode defaults applied"
}

wizard_toggle_mode() {
    if ((GI_EASY_MODE)); then
        GI_EASY_MODE=0
        log_info "installation mode: advanced"
    else
        GI_EASY_MODE=1
        log_info "installation mode: easy"
    fi
}

# Boot mode is hidden in easy mode unless its detected default conflicts with
# the live firmware or the selected disk. In those cases the user must see and
# change it rather than being stuck with an invalid configuration.
wizard_easy_boot_mode_visible() {
    ((GI_EASY_MODE)) || return 0
    local efi_dir=${GI_FIRMWARE_EFI_DIR:-/sys/firmware/efi}
    if [[ $CFG_BOOT_MODE == uefi && ! -d $efi_dir ]]; then
        return 0
    fi
    if [[ $CFG_BOOT_MODE == bios && -d $efi_dir ]]; then
        return 0
    fi
    if [[ $CFG_BOOT_MODE == bios && -n $CFG_DISK && -b $CFG_DISK ]]; then
        local disk_mib
        disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
        ((disk_mib > 2097152)) && return 0
    fi
    return 1
}

# Disk page -----------------------------------------------------------------

wizard_disk_rows() {
    local size disk plan swap home boot
    boot=${CFG_BOOT_MODE^^}
    if [[ -n $CFG_DISK ]]; then
        if size=$(disk_size_mib "$CFG_DISK" 2>/dev/null); then
            disk="$CFG_DISK ($(human_mib "$size"))"
        else
            disk="$CFG_DISK"
        fi
    else
        disk=$(T 'not selected')
    fi
    swap=$CFG_SWAP_MODE
    [[ $CFG_SWAP_MODE == custom ]] && swap+=" (${CFG_SWAP_MIB} MiB)"
    home=$CFG_HOME_MODE
    [[ $CFG_HOME_MODE == separate ]] && home+=" (${CFG_HOME_MIB} MiB)"
    plan=""
    if [[ $CFG_DISK_MODE == auto && -n $CFG_DISK && -b $CFG_DISK ]]; then
        local disk_mib
        disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
        if disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" 2>/dev/null; then
            plan=$(disk_plan_summary)
        else
            plan=$(T 'Plan error: %s' "$PLAN_ERROR")
        fi
    fi
    UI_PAGE_ROWS=()
    if ! ((GI_EASY_MODE)) || wizard_easy_boot_mode_visible; then
        UI_PAGE_ROWS+=("boot|$(T 'Boot mode')|$boot|$(T 'UEFI + GPT or BIOS + MBR')")
    fi
    if ! ((GI_EASY_MODE)) || [[ $CFG_DISK_MODE == manual ]]; then
        UI_PAGE_ROWS+=("diskmode|$(T 'Partitioning mode')|$CFG_DISK_MODE|$(T 'Automatic layout or existing partitions')")
    fi
    UI_PAGE_ROWS+=("disk|$(T 'Target disk')|$disk|$(T 'The selected disk will be wiped')")
    UI_PAGE_ROWS+=("rootfs|$(T 'Root filesystem')|$CFG_ROOT_FS|$(T 'xfs, ext4 or btrfs')")
    if ! ((GI_EASY_MODE)) || [[ $CFG_HOME_MODE == separate ]]; then
        UI_PAGE_ROWS+=("homefs|$(T '/home filesystem')|$CFG_HOME_FS|$(T 'Used for a separate /home')")
    fi
    UI_PAGE_ROWS+=("swap|$(T 'Swap')|$swap|$(T 'Automatic, none or a custom size')")
    if ! ((GI_EASY_MODE)) || [[ $CFG_HOME_MODE == separate ]]; then
        UI_PAGE_ROWS+=("home|$(T '/home')|$home|$(T 'Separate partition or part of root')")
    fi
    if ((!GI_EASY_MODE)) || [[ $CFG_DISK_MODE == manual ]]; then
        UI_PAGE_ROWS+=(
            "manual|$(T 'Assign partitions')|$(T 'Enter to configure')|$(T 'Choose existing partitions and formatting options')"
        )
    fi
    if [[ -n $plan ]]; then
        UI_PAGE_ROWS+=(
            "plan|$(T 'Partition plan')|$plan|$(T 'Enter to inspect the layout')"
        )
    fi
    return 0
}

wizard_disk_edit() {
    local tag=$1 choice default max
    case "$tag" in
        boot)
            if wizard_pick CFG_BOOT_MODE "$(T 'Boot mode')" \
                "$(T 'Current Minimal CD mode: %s' "$([[ -d /sys/firmware/efi ]] && printf UEFI || printf BIOS)")" \
                "$CFG_BOOT_MODE" \
                "uefi|UEFI + GPT|$(T 'ESP at /efi, GRUB bootloader (x86_64-efi)')" \
                "bios|BIOS + MBR|$(T '/boot partition, GRUB bootloader (i386-pc)')"; then
                if [[ $CFG_BOOT_MODE == uefi ]]; then
                    CFG_PART_BOOT=""
                    CFG_UUID_BOOT=""
                else
                    CFG_PART_ESP=""
                    CFG_UUID_ESP=""
                fi
                wizard_save
            fi
            ;;
        diskmode)
            if wizard_pick CFG_DISK_MODE "$(T 'Partitioning mode')" \
                "$(T 'The automatic layout destroys the partition table')" "$CFG_DISK_MODE" \
                "auto|$(T 'Automatic')|$(T 'Create GPT/MBR and partitions according to the plan')" \
                "manual|$(T 'Manual')|$(T 'Use partitions that already exist')"; then
                wizard_clear_partitions
                wizard_save
            fi
            ;;
        disk)
            local previous=$CFG_DISK
            if disks_select_disk; then
                if [[ $CFG_DISK != "$previous" ]]; then
                    wizard_clear_partitions
                fi
                wizard_save
            fi
            ;;
        rootfs)
            if wizard_pick CFG_ROOT_FS "$(T 'Root filesystem')" \
                "$(T 'The filesystem will be created from scratch')" "$CFG_ROOT_FS" \
                "xfs|XFS|$(T 'Reliable default filesystem, recommended for Gentoo')" \
                "ext4|ext4|$(T 'Classic and predictable filesystem')" \
                "btrfs|Btrfs|$(T 'Snapshots and compression; subvolumes are not configured')"; then
                CFG_FORMAT_ROOT=yes
                wizard_save
            fi
            ;;
        homefs)
            wizard_pick CFG_HOME_FS "$(T '/home filesystem')" \
                "$(T 'The filesystem will be created from scratch')" "$CFG_HOME_FS" \
                "xfs|XFS|$(T 'Reliable default filesystem, recommended for Gentoo')" \
                "ext4|ext4|$(T 'Classic and predictable filesystem')" \
                "btrfs|Btrfs|$(T 'Snapshots and compression; subvolumes are not configured')" || true
            ;;
        swap)
            if ui_choice single "$(T 'Swap partition')" \
                "$(T 'Swap can be omitted if there is enough RAM')" "$CFG_SWAP_MODE" \
                "auto|$(T 'Automatic')|$(T 'Gentoo Handbook table: 4-8 GiB depending on RAM')" \
                "none|$(T 'No swap')|$(T 'Do not create a swap partition')" \
                "custom|$(T 'Custom size')|$(T 'Specify the size in MiB')"; then
                choice=$UI_RESULT
                case "$choice" in
                    auto|none)
                        CFG_SWAP_MODE=$choice
                        CFG_SWAP_MIB=0
                        CFG_PART_SWAP=""
                        CFG_UUID_SWAP=""
                        CFG_FORMAT_SWAP=no
                        wizard_save
                        ;;
                    custom)
                        max=1048576
                        if [[ -n $CFG_DISK && -b $CFG_DISK ]]; then
                            max=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '1048576')
                        fi
                        default=$CFG_SWAP_MIB
                        ((default > 0)) || default=$(suggest_swap_mib)
                        if wizard_prompt_int CFG_SWAP_MIB "$(T 'Swap size')" \
                            "$(T 'Enter the swap size in MiB:')" 1 "$max" "$default"; then
                            CFG_SWAP_MODE=custom
                            wizard_save
                        fi
                        ;;
                esac
            fi
            ;;
        home)
            if ui_choice single "$(T '/home partition')" \
                "$(T 'A separate /home makes reinstalling easier')" "$CFG_HOME_MODE" \
                "no|$(T 'No separate /home')|$(T 'Home directories live on the root partition')" \
                "separate|$(T 'Separate /home')|$(T 'Create or use a dedicated partition')"; then
                choice=$UI_RESULT
                if [[ $choice == no ]]; then
                    CFG_HOME_MODE=no
                    CFG_HOME_MIB=0
                    CFG_PART_HOME=""
                    CFG_UUID_HOME=""
                    CFG_FORMAT_HOME=no
                    wizard_save
                else
                    max=1048576
                    if [[ -n $CFG_DISK && -b $CFG_DISK ]]; then
                        max=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '1048576')
                        ((max > 9216)) && max=$((max - 9216))
                    fi
                    ((max < 1024)) && max=1024
                    default=$CFG_HOME_MIB
                    ((default > 0)) || default=32768
                    ((default > max)) && default=$max
                    if wizard_prompt_int CFG_HOME_MIB "$(T '/home size')" \
                        "$(T 'Enter the /home size in MiB:')" 1024 "$max" "$default"; then
                        CFG_HOME_MODE=separate
                        wizard_save
                    fi
                fi
            fi
            ;;
        manual)
            if [[ -z $CFG_DISK || ! -b $CFG_DISK ]]; then
                disks_select_disk || return 0
            fi
            if disks_manual_assign; then
                CFG_DISK_MODE=manual
                if disks_manual_options; then
                    GI_MANUAL_OPTIONS_READY=1
                    wizard_save
                fi
            fi
            ;;
        plan)
            ui_msg "$(T 'Partition plan')" "$(disk_plan_print)" || true
            ;;
    esac
}

wizard_disk_validate() {
    config_derived
    if [[ $CFG_DISK_MODE == auto ]]; then
        if [[ -z $CFG_DISK || ! -b $CFG_DISK ]]; then
            UI_PAGE_MESSAGE=$(T 'Select a target disk before continuing.')
            return 1
        fi
    else
        if [[ -z $CFG_PART_ROOT || ! -b $CFG_PART_ROOT ]]; then
            UI_PAGE_MESSAGE=$(T 'Assign the manual partitions before continuing.')
            return 1
        fi
    fi
    return 0
}

wizard_page_disk() {
    local body
    body=$(T 'All settings are collected first. The disk is changed only after the final confirmation on the review page.')
    ui_page_run "$(T 'Boot and disk')" "$body" wizard_disk_rows wizard_disk_edit wizard_disk_validate
}

# System page ---------------------------------------------------------------

wizard_system_rows() {
    UI_PAGE_ROWS=(
        "hostname|$(T 'Hostname')|$CFG_HOSTNAME|$(T 'Latin letters, digits, dots and hyphens')"
        "timezone|$(T 'Timezone')|$CFG_TIMEZONE|$(T 'For example Europe/Moscow or UTC')"
        "locale|$(T 'Locale')|$CFG_LOCALE|$(T 'For example en_US.UTF-8')"
        "keymap|$(T 'Console keymap')|$CFG_KEYMAP|$(T 'For example us or ru')"
        "hwclock|$(T 'Hardware clock')|$CFG_HWCLOCK|$(T 'UTC or local')"
    )
    if ! ((GI_EASY_MODE)); then
        UI_PAGE_ROWS+=(
            "language|$(T 'Installer language')|$(i18n_language_label "${CFG_UI_LANGUAGE:-en}")|$(T 'English or Russian interface')"
        )
    fi
}

wizard_system_edit() {
    local tag=$1
    case "$tag" in
        hostname)
            wizard_prompt CFG_HOSTNAME "$(T 'Hostname')" "$(T 'Enter the hostname:')" \
                validate_hostname "$(T 'Latin letters, digits, dots and hyphens')" || true
            ;;
        timezone)
            wizard_prompt CFG_TIMEZONE "$(T 'Timezone')" "$(T 'Enter the IANA zone:')" \
                validate_timezone "$(T 'For example: Europe/Moscow or UTC')" || true
            ;;
        locale)
            wizard_prompt CFG_LOCALE "$(T 'Locale')" "$(T 'Enter a UTF-8 locale:')" \
                validate_locale "$(T 'For example: ru_RU.UTF-8 or en_US.UTF-8')" || true
            ;;
        keymap)
            wizard_prompt CFG_KEYMAP "$(T 'Console keymap')" "$(T 'Enter the keymap:')" \
                validate_keymap "$(T 'For example: us or ru')" || true
            ;;
        hwclock)
            wizard_pick CFG_HWCLOCK "$(T 'Hardware clock')" "$(T 'How time is stored in the RTC')" \
                "$CFG_HWCLOCK" \
                "UTC|UTC|$(T 'Recommended, especially for dual boot')" \
                "local|Local|$(T 'Local time')" || true
            ;;
        language)
            i18n_choose_language
            ;;
    esac
}

wizard_system_validate() {
    validate_hostname "$CFG_HOSTNAME" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    validate_timezone "$CFG_TIMEZONE" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    validate_locale "$CFG_LOCALE" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    validate_keymap "$CFG_KEYMAP" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    return 0
}

wizard_page_system() {
    ui_page_run "$(T 'System')" \
        "$(T 'Hostname, time, locale, console and interface language')" \
        wizard_system_rows wizard_system_edit wizard_system_validate
}

# Stage3 and build page -----------------------------------------------------

wizard_build_rows() {
    local jobs flavor
    jobs=$CFG_MAKE_JOBS
    [[ $CFG_MAKE_JOBS == auto ]] && jobs="$(T 'Automatic') ($(make_jobs_suggestion))"
    case "$CFG_STAGE_FLAVOR" in
        desktop-openrc) flavor="OpenRC ($(T 'desktop Stage3'))" ;;
        desktop-systemd) flavor="systemd ($(T 'desktop Stage3'))" ;;
        openrc) flavor="OpenRC" ;;
        systemd) flavor="systemd" ;;
        *) flavor=$CFG_STAGE_FLAVOR ;;
    esac
    UI_PAGE_ROWS=(
        "flavor|$(T 'Init system and Stage3')|$flavor|$(T 'OpenRC or systemd; the desktop Stage3 follows the desktop choice automatically')"
    )
    if ! ((GI_EASY_MODE)); then
        UI_PAGE_ROWS+=(
            "mirror|$(T 'Mirror')|$CFG_MIRROR|$(T 'Base distfiles.gentoo.org URL')"
            "stageurl|$(T 'Direct Stage3 URL')|${CFG_STAGE_URL:-$(T 'automatic')}|$(T 'Empty - use latest-stage3')"
            "profile|$(T 'Portage profile (derived)')|$CFG_PROFILE|$(T 'Usually derived from the init system and desktop; change only if needed')"
            "cpu|$(T 'CPU_FLAGS_X86')|$(wizard_bool_text "$CFG_CPU_FLAGS")|$(T 'Detect with cpuid2cpuflags')"
            "world|$(T 'Update @world')|$(wizard_bool_text "$CFG_UPDATE_WORLD")|$(T 'Can take a long time')"
            "jobs|$(T 'MAKEOPTS')|$jobs|$(T 'Number of parallel build jobs')"
            "cflags|CFLAGS|$CFG_CFLAGS|$(T 'Compiler flags')"
            "use|$(T 'Extra USE')|${CFG_USE_EXTRA:-$(T 'none')}|$(T 'Additional USE flags')"
        )
    fi
}

wizard_build_edit() {
    local tag=$1 choice value
    case "$tag" in
        flavor)
            wizard_pick CFG_STAGE_FLAVOR "$(T 'Init system and Stage3')" \
                "$(T 'Choose OpenRC or systemd. A desktop Stage3 is selected automatically when a desktop environment is chosen.')" \
                "${CFG_STAGE_FLAVOR#desktop-}" \
                "openrc|OpenRC|$(T 'Classic Gentoo init system')" \
                "systemd|systemd|$(T 'systemd init system')" || true
            ;;
        mirror)
            wizard_prompt CFG_MIRROR "$(T 'distfiles mirror')" "$(T 'Mirror base URL:')" \
                validate_url "$(T 'For example: https://distfiles.gentoo.org')" || true
            ;;
        stageurl)
            wizard_prompt CFG_STAGE_URL "$(T 'Direct Stage3 URL')" \
                "$(T 'Leave empty for automatic selection:')" validate_optional_url \
                "$(T 'Full URL to the .tar.xz file')" || true
            ;;
        profile)
            wizard_pick CFG_PROFILE "$(T 'Portage profile')" \
                "$(T 'The profile controls USE flags and the package set')" "$CFG_PROFILE" \
                "stage|Stage|$(T 'Base profile without a desktop')" \
                "desktop|Desktop|$(T 'Desktop profile')" \
                "gnome|GNOME|$(T 'Desktop + GNOME')" \
                "kde|KDE Plasma|$(T 'Desktop + KDE')" \
                "hardened|Hardened|$(T 'Additional hardening')" || true
            ;;
        cpu)
            wizard_pick_bool CFG_CPU_FLAGS "$(T 'CPU_FLAGS_X86')" \
                "$(T 'Detect CPU flags with cpuid2cpuflags?')" || true
            ;;
        world)
            wizard_pick_bool CFG_UPDATE_WORLD "$(T 'Update @world')" \
                "$(T 'Run emerge --update --deep --newuse @world? This can take a long time.')" || true
            ;;
        jobs)
            if ui_choice single "$(T 'MAKEOPTS')" "$(T 'Number of parallel build jobs')" \
                "$([[ $CFG_MAKE_JOBS == auto ]] && printf auto || printf custom)" \
                "auto|$(T 'Automatic')|$(T 'Based on CPU and RAM: %s' "$(make_jobs_suggestion)")" \
                "custom|$(T 'Specify a number')|$(T 'Enter it manually')"; then
                if [[ $UI_RESULT == custom ]]; then
                    value=$(make_jobs_suggestion)
                    wizard_prompt_int CFG_MAKE_JOBS "$(T 'MAKEOPTS')" \
                        "$(T 'Number of make jobs:')" 1 256 "$value" || true
                else
                    CFG_MAKE_JOBS=auto
                    wizard_save
                fi
            fi
            ;;
        cflags)
            wizard_prompt CFG_CFLAGS CFLAGS "$(T 'Compiler flags:')" validate_cflags \
                "$(T 'Usually: -march=native -O2 -pipe')" || true
            ;;
        use)
            wizard_prompt CFG_USE_EXTRA "$(T 'USE flags')" \
                "$(T 'Additional USE flags (space-separated):')" validate_use_flags \
                "$(T 'For example: cups bluetooth')" || true
            ;;
    esac
    # Keep the profile in sync after changing the Stage3 or desktop variant.
    config_derived
}

wizard_build_validate() {
    validate_url "$CFG_MIRROR" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    if [[ -n $CFG_STAGE_URL ]]; then
        validate_url "$CFG_STAGE_URL" 2>/dev/null || {
            UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
            return 1
        }
    fi
    validate_cflags "$CFG_CFLAGS" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    validate_use_flags "$CFG_USE_EXTRA" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    if [[ $CFG_MAKE_JOBS != auto ]]; then
        validate_int_range "$CFG_MAKE_JOBS" 1 256 2>/dev/null || {
            UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
            return 1
        }
    fi
    return 0
}

wizard_page_build() {
    ui_page_run "$(T 'Stage3 and build options')" \
        "$(T 'Choose OpenRC or systemd, then the Stage3 source and package build settings')" \
        wizard_build_rows wizard_build_edit wizard_build_validate
}

# Kernel page ---------------------------------------------------------------

wizard_kernel_rows() {
    local mode
    case "$CFG_KERNEL_MODE" in
        bin) mode="$(T 'Binary (gentoo-kernel-bin)')" ;;
        dist) mode="$(T 'Compiled (gentoo-kernel)')" ;;
        auto) mode="$(T 'Automatic (generated config)')" ;;
        manual) mode="$(T 'Manual (gentoo-sources + menuconfig)')" ;;
        *) mode="$(T 'not selected')" ;;
    esac
    UI_PAGE_ROWS=(
        "mode|$(T 'Kernel installation method')|$mode|$(T 'Choose binary or compiled explicitly')"
        "firmware|linux-firmware|$(wizard_bool_text "$CFG_FIRMWARE")|$(T 'Needed for Wi-Fi, GPUs and more')"
    )
    if ! ((GI_EASY_MODE)); then
        UI_PAGE_ROWS+=(
            "microcode|$(T 'CPU microcode')|$CFG_MICROCODE|$(T 'auto, none, intel or amd')"
            "cmdline|$(T 'Kernel cmdline')|${CFG_KERNEL_CMDLINE:-$(T 'empty')}|$(T 'Additional kernel parameters')"
        )
    fi
    UI_PAGE_ROWS+=("boot|$(T 'Bootloader')|$CFG_BOOTLOADER|$(T 'Only GRUB is supported in this version')")
}

wizard_kernel_edit() {
    local tag=$1
    case "$tag" in
        mode)
            wizard_pick CFG_KERNEL_MODE "$(T 'Kernel installation method')" \
                "$(T 'Choose how to obtain the kernel')" "$CFG_KERNEL_MODE" \
                "bin|$(T 'Binary (gentoo-kernel-bin)')|$(T 'Prebuilt binary kernel, fast')" \
                "dist|$(T 'Compiled (gentoo-kernel)')|$(T 'Built with the Gentoo configuration')" \
                "auto|$(T 'Automatic (generated config)')|$(T 'gentoo-sources with a .config generated from this hardware; no menuconfig')" \
                "manual|$(T 'Manual (gentoo-sources)')|$(T 'Configuration with menuconfig; this step remains interactive')" || true
            ;;
        firmware)
            wizard_pick_bool CFG_FIRMWARE "$(T 'Device firmware')" \
                "$(T 'Install sys-kernel/linux-firmware? The package is large.')" || true
            ;;
        microcode)
            wizard_pick CFG_MICROCODE "$(T 'CPU microcode')" \
                "$(T 'Microcode updates are loaded at boot')" "$CFG_MICROCODE" \
                "auto|$(T 'Automatic')|$(T 'Detect the CPU vendor')" \
                "none|$(T 'Do not install')|" \
                "intel|Intel|sys-firmware/intel-microcode" \
                "amd|AMD|sys-firmware/amd-ucode" || true
            ;;
        cmdline)
            wizard_prompt CFG_KERNEL_CMDLINE "$(T 'Kernel cmdline')" \
                "$(T 'Additional parameters (root is added automatically):')" \
                validate_kernel_cmdline "$(T 'For example: quiet splash')" || true
            ;;
        boot)
            ui_msg "$(T 'Bootloader')" "$(T 'This version supports GRUB for UEFI and BIOS only.')" || true
            ;;
    esac
}

wizard_kernel_validate() {
    case "$CFG_KERNEL_MODE" in
        bin|dist|auto|manual) ;;
        *)
            UI_PAGE_MESSAGE=$(T 'Choose the binary, compiled or automatic kernel explicitly.')
            return 1
            ;;
    esac
    case "$CFG_MICROCODE" in
        auto|none|intel|amd) ;;
        *)
            UI_PAGE_MESSAGE=$(T 'Microcode: auto, none, intel or amd.')
            return 1
            ;;
    esac
    validate_kernel_cmdline "$CFG_KERNEL_CMDLINE" 2>/dev/null || {
        UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
        return 1
    }
    return 0
}

wizard_page_kernel() {
    local body
    body=$(T 'The kernel is an explicit choice: a prebuilt binary, a kernel compiled with the Gentoo configuration, an automatically generated configuration, or manual menuconfig. Only manual configuration remains interactive.')
    ui_page_run "$(T 'Kernel and bootloader')" "$body" \
        wizard_kernel_rows wizard_kernel_edit wizard_kernel_validate
}

# Users and accounts page ---------------------------------------------------

wizard_users_rows() {
    local root_state user_state
    [[ -n ${GI_ROOT_PASSWORD:-} ]] && root_state=$(T 'set') || root_state=$(T 'not set')
    [[ -n ${GI_USER_PASSWORD:-} ]] && user_state=$(T 'set') || user_state=$(T 'not set')
    UI_PAGE_ROWS=(
        "createuser|$(T 'Create a regular user')|$(wizard_bool_text "$CFG_CREATE_USER")|$(T 'Do not create an account silently')"
        "username|$(T 'User name')|${CFG_USERNAME:-$(T 'not set')}|$(T 'Lowercase Latin letters, digits, _ and -')"
        "rootpass|$(T 'Root password')|$root_state|$(T 'Kept in memory only, never saved to disk')"
        "userpass|$(T 'User password')|$user_state|$(T 'Kept in memory only, never saved to disk')"
        "sudo|$(T 'Install sudo')|$(wizard_bool_text "$CFG_SUDO")|$(T 'Rule for the wheel group')"
    )
}

wizard_users_edit() {
    local tag=$1
    case "$tag" in
        createuser)
            wizard_pick_bool CFG_CREATE_USER "$(T 'User account')" \
                "$(T 'Create a regular user?')" || true
            if [[ $CFG_CREATE_USER == yes && -z $CFG_USERNAME ]]; then
                wizard_prompt CFG_USERNAME "$(T 'User name')" "$(T 'Enter the user name:')" \
                    validate_username "$(T 'Lowercase Latin letters, digits, _ and -')" || true
            fi
            ;;
        username)
            if [[ $CFG_CREATE_USER != yes ]]; then
                ui_msg "$(T 'User account')" "$(T 'Enable "Create a regular user" first.')" || true
                return 0
            fi
            wizard_prompt CFG_USERNAME "$(T 'User name')" "$(T 'Enter the user name:')" \
                validate_username "$(T 'Lowercase Latin letters, digits, _ and -')" || true
            ;;
        rootpass)
            if ui_password_twice "$(T 'Root password')"; then
                GI_ROOT_PASSWORD=$UI_SECRET
                UI_SECRET=""
                UI_RESULT=""
                log_info "root password collected in memory"
            fi
            ;;
        userpass)
            if [[ $CFG_CREATE_USER != yes ]]; then
                ui_msg "$(T 'User account')" "$(T 'Enable "Create a regular user" first.')" || true
                return 0
            fi
            if [[ -z $CFG_USERNAME ]]; then
                ui_msg "$(T 'User name')" "$(T 'Set the user name first.')" || true
                return 0
            fi
            if ui_password_twice "$(T 'Password for user %s' "$CFG_USERNAME")"; then
                GI_USER_PASSWORD=$UI_SECRET
                UI_SECRET=""
                UI_RESULT=""
                log_info "user password collected in memory"
            fi
            ;;
        sudo)
            wizard_pick_bool CFG_SUDO "$(T 'sudo')" \
                "$(T 'Install sudo and allow the wheel group?')" || true
            ;;
    esac
}

wizard_users_validate() {
    if [[ $CFG_CREATE_USER == yes ]]; then
        validate_username "$CFG_USERNAME" 2>/dev/null || {
            UI_PAGE_MESSAGE=$VALIDATION_MESSAGE
            return 1
        }
    fi
    if ! state_is_done system; then
        if [[ -z ${GI_ROOT_PASSWORD:-} ]]; then
            UI_PAGE_MESSAGE=$(T 'Set the root password before continuing.')
            return 1
        fi
        if [[ $CFG_CREATE_USER == yes && -z ${GI_USER_PASSWORD:-} ]]; then
            UI_PAGE_MESSAGE=$(T 'Set the user password before continuing.')
            return 1
        fi
    fi
    return 0
}

wizard_page_users() {
    local body
    body=$(T 'Passwords are used during the unattended installation and are kept in process memory only. They are never written to the configuration, state or logs.')
    ui_page_run "$(T 'Users and accounts')" "$body" \
        wizard_users_rows wizard_users_edit wizard_users_validate
}

# Services page -------------------------------------------------------------

wizard_services_rows() {
    local optional=""
    [[ $CFG_SSH == yes ]] && optional+="SSH "
    [[ $CFG_CRON == yes ]] && optional+="cron "
    [[ $CFG_CHRONY == yes ]] && optional+="chrony "
    [[ $CFG_SYSLOG == yes ]] && optional+="syslog "
    optional=${optional% }
    [[ -n $optional ]] || optional=$(T 'none')
    UI_PAGE_ROWS=(
        "network|$(T 'Network')|$CFG_NETWORK|$(T 'dhcpcd, NetworkManager or no configuration')"
        "optional|$(T 'Optional services')|$optional|$(T 'Space toggles SSH, cron, chrony and syslog')"
    )
}

wizard_services_edit() {
    local tag=$1 default=""
    case "$tag" in
        network)
            wizard_pick CFG_NETWORK "$(T 'Network configuration')" \
                "$(T 'Automatic configuration over DHCP')" "$CFG_NETWORK" \
                "dhcpcd|dhcpcd|$(T 'Simple DHCP client')" \
                "networkmanager|NetworkManager|$(T 'Convenient for Wi-Fi and desktops')" \
                "none|$(T 'No configuration')|$(T 'Configure networking manually after installation')" || true
            ;;
        optional)
            [[ $CFG_SSH == yes ]] && default+="ssh,"
            [[ $CFG_CRON == yes ]] && default+="cron,"
            [[ $CFG_CHRONY == yes ]] && default+="chrony,"
            [[ $CFG_SYSLOG == yes ]] && default+="syslog,"
            default=${default%,}
            if ui_choice multi "$(T 'Optional services')" \
                "$(T 'Space selects the services to install and enable')" "$default" \
                "ssh|OpenSSH|$(T 'Remote shell access')" \
                "cron|cronie|$(T 'Scheduled jobs')" \
                "chrony|chrony|$(T 'Time synchronization')" \
                "syslog|sysklogd / rsyslog|$(T 'System logging')"; then
                CFG_SSH=no CFG_CRON=no CFG_CHRONY=no CFG_SYSLOG=no
                for tag in "${UI_RESULTS[@]}"; do
                    case "$tag" in
                        ssh) CFG_SSH=yes ;;
                        cron) CFG_CRON=yes ;;
                        chrony) CFG_CHRONY=yes ;;
                        syslog) CFG_SYSLOG=yes ;;
                    esac
                done
                wizard_save
            fi
            ;;
    esac
}

wizard_page_services() {
    ui_page_run "$(T 'Services')" \
        "$(T 'Network, remote access, scheduled jobs, time synchronization and logging')" \
        wizard_services_rows wizard_services_edit
}

# Desktop page --------------------------------------------------------------

wizard_desktop_rows() {
    local video_note
    UI_PAGE_ROWS=(
        "desktop|$(T 'Desktop environment')|$(desktop_label)|$(T 'XFCE, GNOME or a console-only system')"
    )
    if desktop_is_enabled; then
        if ((GI_EASY_MODE)) && [[ -n $CFG_VIDEO_CARDS ]]; then
            video_note=$(T 'Auto-detected; switch to Advanced mode to change it')
        else
            video_note=$(T 'Detected automatically; Enter to choose')
        fi
        UI_PAGE_ROWS+=(
            "video|VIDEO_CARDS|${CFG_VIDEO_CARDS:-$(T 'not set')}|$video_note"
        )
    fi
}

wizard_desktop_edit() {
    local tag=$1 old_profile=$CFG_PROFILE detected current
    case "$tag" in
        desktop)
            if wizard_pick CFG_DESKTOP "$(T 'Desktop environment')" \
                "$(T 'XFCE or GNOME; the Portage profile follows the choice')" "$CFG_DESKTOP" \
                "none|$(T 'No desktop environment')|$(T 'Install a console-only system')" \
                "xfce|XFCE + LightDM|$(T 'Lightweight desktop for everyday use')" \
                "gnome|GNOME + GDM|$(T 'Full GNOME environment; many packages')"; then
                if [[ $CFG_PROFILE != "$old_profile" ]] && state_is_done portage; then
                    ui_msg "$(T 'Profile changed after Portage')" \
                        "$(T 'Portage is already complete, so the new profile %s will not be\napplied to the installed system.' "$CFG_PROFILE")" || true
                fi
            fi
            ;;
        video)
            if ((GI_EASY_MODE)) && [[ -n $CFG_VIDEO_CARDS ]]; then
                ui_msg "$(T 'VIDEO_CARDS')" \
                    "$(T 'Detected automatically. Switch to Advanced mode to change it.')" || true
                return 0
            fi
            detected=$(hardware_detect_video_cards)
            case "$CFG_VIDEO_CARDS" in
                ""|intel|"amdgpu radeonsi"|nouveau|nvidia|vmware|qxl|virgl)
                    current=$CFG_VIDEO_CARDS
                    ;;
                *) current=custom ;;
            esac
            [[ -n $current ]] || current=none
            if ui_choice single "$(T 'VIDEO_CARDS')" \
                "$(T 'Choose the GPU drivers used by Portage. Automatic detection is recommended.')" "$current" \
                "auto|$(T 'Detect automatically')|$(T 'Detected: %s' "${detected:-$(T 'not detected')}")" \
                "intel|Intel|$(T 'Integrated Intel graphics')" \
                "amdgpu radeonsi|AMD|$(T 'Modern AMD GPUs (amdgpu + radeonsi)')" \
                "nouveau|NVIDIA (open)|$(T 'Open-source NVIDIA driver')" \
                "nvidia|NVIDIA (proprietary)|$(T 'Proprietary nvidia-drivers')" \
                "vmware|VMware|$(T 'VMware SVGA (vmwgfx)')" \
                "qxl|QEMU QXL|$(T 'QEMU virtual display')" \
                "virgl|Virtio GPU|$(T 'virtio-gpu with virgl')" \
                "none|$(T 'No acceleration')|$(T 'Use the Xorg modesetting driver')" \
                "custom|$(T 'Custom value')|$(T 'Enter VIDEO_CARDS manually')"; then
                case "$UI_RESULT" in
                    auto)
                        if [[ -n $detected ]]; then
                            CFG_VIDEO_CARDS=$detected
                        else
                            CFG_VIDEO_CARDS=""
                            ui_msg "$(T 'No GPU detected')" \
                                "$(T 'No supported GPU was detected; Xorg will use the modesetting driver.')" || true
                        fi
                        ;;
                    none) CFG_VIDEO_CARDS="" ;;
                    custom)
                        wizard_prompt CFG_VIDEO_CARDS VIDEO_CARDS \
                            "$(T 'Video drivers (space-separated, may be empty):')" validate_optional_tokens \
                            "$(T 'For example: amdgpu radeonsi or intel')" || true
                        ;;
                    *) CFG_VIDEO_CARDS=$UI_RESULT ;;
                esac
                wizard_save
            fi
            ;;
    esac
}

wizard_desktop_validate() {
    if desktop_is_enabled && [[ -z $CFG_VIDEO_CARDS ]]; then
        UI_PAGE_MESSAGE=$(T 'VIDEO_CARDS is empty: Xorg may run without acceleration. Set it or continue if a basic mode is acceptable.')
    fi
    return 0
}

wizard_page_desktop() {
    ui_page_run "$(T 'Desktop environment')" \
        "$(T 'An explicit choice: no desktop, XFCE or GNOME')" \
        wizard_desktop_rows wizard_desktop_edit wizard_desktop_validate
}

# Review page ---------------------------------------------------------------

wizard_review_text() {
    local disk size swap home root_state
    if [[ -n $CFG_DISK ]] && size=$(disk_size_mib "$CFG_DISK" 2>/dev/null); then
        disk="$CFG_DISK ($(human_mib "$size"))"
    else
        disk=${CFG_DISK:-$(T 'not selected')}
    fi
    swap=$CFG_SWAP_MODE
    [[ $CFG_SWAP_MODE == custom ]] && swap+=" (${CFG_SWAP_MIB} MiB)"
    home=$CFG_HOME_MODE
    [[ $CFG_HOME_MODE == separate ]] && home+=" (${CFG_HOME_MIB} MiB)"
    if [[ -n ${GI_ROOT_PASSWORD:-} ]]; then root_state=$(T 'set'); else root_state=$(T 'not set'); fi
    printf '%s\n' "$(T 'Boot: %s · Disk: %s · Mode: %s' "${CFG_BOOT_MODE^^}" "$disk" "$CFG_DISK_MODE")"
    printf '%s\n' "$(T 'Filesystems: root %s · /home %s · swap %s · /home mode %s' "$CFG_ROOT_FS" "$CFG_HOME_FS" "$swap" "$home")"
    printf '%s\n' "$(T 'Stage3: %s · Profile: %s (%s)' "$CFG_STAGE_FLAVOR" "$CFG_PROFILE" "$CFG_INIT")"
    printf '%s\n' "$(T 'Kernel: %s · firmware: %s · microcode: %s · bootloader: %s' \
        "${CFG_KERNEL_MODE:-$(T 'not selected')}" "$CFG_FIRMWARE" "$CFG_MICROCODE" "$CFG_BOOTLOADER")"
    printf '%s\n' "$(T 'System: %s · %s · %s · keymap %s' "$CFG_HOSTNAME" "$CFG_TIMEZONE" "$CFG_LOCALE" "$CFG_KEYMAP")"
    printf '%s\n' "$(T 'Services: network %s · SSH %s · cron %s · chrony %s · syslog %s · sudo %s' \
        "$CFG_NETWORK" "$CFG_SSH" "$CFG_CRON" "$CFG_CHRONY" "$CFG_SYSLOG" "$CFG_SUDO")"
    printf '%s\n' "$(T 'Desktop: %s · VIDEO_CARDS: %s' "$(desktop_label)" "${CFG_VIDEO_CARDS:-$(T 'not set')}")"
    printf '%s\n' "$(T 'User: %s (create: %s) · root password: %s' "$CFG_USERNAME" "$CFG_CREATE_USER" "$root_state")"
}

wizard_review_rows() {
    UI_PAGE_BODY=$(wizard_review_text)
    UI_PAGE_ROWS=(
        "details|$(T 'Full configuration summary')|$(T 'Enter to open')|$(T 'Opens in a pager')"
    )
}

wizard_review_edit() {
    local tag=$1 tmp
    case "$tag" in
        details)
            tmp=$(mktemp "${GI_WORKDIR}/summary.XXXXXX")
            wizard_summary_text >"$tmp"
            chmod 0600 -- "$tmp"
            ui_show_file "$(T 'Configuration summary')" "$tmp" || true
            rm -f -- "$tmp"
            ;;
    esac
}

wizard_confirm_installation() {
    local summary login body warning_block="" confirm_label warning
    config_derived
    login=$(T 'root only')
    [[ $CFG_CREATE_USER == yes ]] && login=$CFG_USERNAME
    summary=$(T 'Boot: %s · Disk: %s · Kernel: %s · Desktop: %s · User: %s' \
        "${CFG_BOOT_MODE^^}" "${CFG_DISK:-$(T 'not selected')}" \
        "${CFG_KERNEL_MODE:-$(T 'not selected')}" "$(desktop_label)" "$login")
    config_check_consistency || true
    if ((${#CONFIG_WARNINGS[@]})); then
        warning_block="$(T 'Configuration warnings:')"$'\n'
        for warning in "${CONFIG_WARNINGS[@]}"; do
            warning_block+="• ${warning}"$'\n'
        done
        warning_block+=$'\n'
        confirm_label=$(T 'Continue anyway')
    else
        confirm_label=$(T 'Confirm')
    fi
    body="$summary"$'\n\n'
    [[ -n $warning_block ]] && body+="$warning_block"
    if state_is_done disk; then
        body+="$(T 'All settings have been collected. The installation will continue without further questions.')"
    else
        body+="$(T 'All settings have been collected. The disk %s will be wiped and formatted, then the installation will run without further questions.\n\nThis cannot be undone.' "${CFG_DISK:-$(T 'not selected')}")"
    fi
    ui_modal_confirm "$(T 'Start the installation?')" "$body" no "$confirm_label" "$(T 'Cancel')"
}

wizard_review_validate() {
    local error errors=""
    UI_PAGE_MESSAGE=""
    config_derived
    if ! config_validate; then
        for error in "${VALIDATION_ERRORS[@]}"; do
            errors+="• ${error}"$'\n'
        done
        UI_PAGE_MESSAGE=$errors
        return 1
    fi
    if ! wizard_ensure_passwords; then
        UI_PAGE_MESSAGE=$(T 'Passwords are required to finish the installation.')
        return 1
    fi
    if ! wizard_confirm_installation; then
        UI_PAGE_MESSAGE=$(T 'Installation was not started.')
        return 1
    fi
    GI_INSTALL_CONFIRMED=1
    GI_UNATTENDED=1
    wizard_save
    log_info "installation confirmed on the review page"
    return 0
}

wizard_page_review() {
    ui_page_run "$(T 'Review and install')" \
        "$(T 'Check the configuration, then confirm the installation')" \
        wizard_review_rows wizard_review_edit wizard_review_validate
}

# Setup sequence ------------------------------------------------------------

WIZARD_PAGES=(disk system build kernel users services desktop review)

wizard_run_setup() {
    local i=0 rc=0 page
    local total=${#WIZARD_PAGES[@]}
    wizard_apply_mode_defaults
    # A new pass through the settings requires a fresh final confirmation.
    GI_INSTALL_CONFIRMED=0
    GI_UNATTENDED=0
    GI_STEP_TOTAL=$total
    while ((i < total)); do
        page=${WIZARD_PAGES[$i]}
        GI_STEP_INDEX=$((i + 1))
        rc=0
        "wizard_page_${page}" || rc=$?
        if ((rc == 0)); then
            i=$((i + 1))
            continue
        fi
        if ((rc == 1)); then
            if ((i == 0)); then
                if ui_modal_confirm "$(T 'Leave the setup?')" \
                    "$(T 'Settings entered so far are saved. The installation has not started.')" no; then
                    GI_STEP_INDEX=0
                    return 2
                fi
            else
                i=$((i - 1))
            fi
            continue
        fi
        GI_STEP_INDEX=0
        return 2
    done
    GI_STEP_INDEX=0
    return 0
}

# Passwords are interactive-only and kept in process memory.
wizard_ensure_passwords() {
    if state_is_done system; then
        return 0
    fi
    if [[ -z ${GI_ROOT_PASSWORD:-} ]]; then
        ui_password_twice "$(T 'Root password')" || return 1
        GI_ROOT_PASSWORD=$UI_SECRET
        UI_SECRET=""
        UI_RESULT=""
        log_info "root password collected in memory"
    fi
    if [[ $CFG_CREATE_USER == yes && -z ${GI_USER_PASSWORD:-} ]]; then
        ui_password_twice "$(T 'Password for user %s' "$CFG_USERNAME")" || return 1
        GI_USER_PASSWORD=$UI_SECRET
        UI_SECRET=""
        UI_RESULT=""
        log_info "user password collected in memory"
    fi
    return 0
}

# Summary and main menu -----------------------------------------------------

wizard_update_summary() {
    local step done=0 disk size fs progress boot kernel
    for step in "${STATE_STEPS[@]}"; do
        [[ ${STATE_DONE[$step]:-0} == 1 ]] && done=$((done + 1))
    done
    boot=${CFG_BOOT_MODE^^}
    fs="$CFG_ROOT_FS"
    [[ $CFG_HOME_MODE == separate ]] && fs+=" / $CFG_HOME_FS"
    if [[ -n $CFG_DISK ]]; then
        if size=$(disk_size_mib "$CFG_DISK" 2>/dev/null); then
            disk="$CFG_DISK ($(human_mib "$size"))"
        else
            disk="$CFG_DISK"
        fi
    else
        disk=$(T 'not selected')
    fi
    kernel=${CFG_KERNEL_MODE:-$(T 'not selected')}
    progress="$done/${#STATE_STEPS[@]}"
    UI_MENU_SUMMARY=(
        "$(T 'Boot: %s · Disk: %s · FS: %s' "$boot" "$disk" "$fs")"
        "$(T 'Stage3: %s · Kernel: %s · Desktop: %s' "$CFG_STAGE_FLAVOR" "$kernel" "$(desktop_label)")"
        "$(T 'Progress: %s steps · Language: %s · Locale: %s' "$progress" "$(i18n_language_label "${CFG_UI_LANGUAGE:-en}")" "$CFG_LOCALE")"
    )
}

ui_on_summary() {
    wizard_update_summary
}

ui_on_save() {
    wizard_save
    ui_msg "$(T 'Saved')" "$(T 'Configuration written to %s.' "$GI_CONFIG_FILE")"
}

wizard_summary_text() {
    local disk_mib="" plan="" size
    if [[ $CFG_DISK_MODE == auto && -n $CFG_DISK && -b $CFG_DISK ]]; then
        disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
        if disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" 2>/dev/null; then
            plan=$(disk_plan_print)
        else
            plan=$(T 'Plan error: %s' "$PLAN_ERROR")
        fi
    fi
    if [[ -n $CFG_DISK ]] && size=$(disk_size_mib "$CFG_DISK" 2>/dev/null); then
        size=$(human_mib "$size")
    else
        size=$(T 'unknown')
    fi
    printf '%s\n' "$(T 'Boot mode: %s' "$CFG_BOOT_MODE")"
    printf '%s\n' "$(T 'Disk mode: %s' "$CFG_DISK_MODE")"
    printf '%s\n' "$(T 'Disk: %s (%s)' "${CFG_DISK:-$(T 'not selected')}" "$size")"
    printf '%s\n' "$(T 'Root FS: %s; /home FS: %s' "$CFG_ROOT_FS" "$CFG_HOME_FS")"
    printf '%s\n\n' "$(T 'Swap: %s; /home: %s' "$CFG_SWAP_MODE" "$CFG_HOME_MODE")"
    if [[ -n $plan ]]; then
        printf '%s\n' "$plan"
    fi
    printf '%s\n' "$(T 'Stage3: %s' "$CFG_STAGE_FLAVOR")"
    printf '%s\n' "$(T 'Mirror: %s' "$CFG_MIRROR")"
    [[ -n $CFG_STAGE_URL ]] && printf '%s\n' "$(T 'Direct URL: %s' "$CFG_STAGE_URL")"
    printf '%s\n' "$(T 'Profile: %s (%s)' "$CFG_PROFILE" "$CFG_INIT")"
    printf '%s\n' "$(T 'Desktop environment: %s' "$(desktop_label)")"
    printf '%s\n' "$(T 'CPU_FLAGS: %s; MAKEOPTS: %s; @world: %s' "$CFG_CPU_FLAGS" "$CFG_MAKE_JOBS" "$CFG_UPDATE_WORLD")"
    printf '%s\n' "$(T 'CFLAGS: %s' "$CFG_CFLAGS")"
    [[ -n $CFG_VIDEO_CARDS ]] && printf '%s\n' "$(T 'VIDEO_CARDS: %s' "$CFG_VIDEO_CARDS")"
    [[ -n $CFG_USE_EXTRA ]] && printf '%s\n' "$(T 'USE: %s' "$CFG_USE_EXTRA")"
    printf '\n%s\n' "$(T 'Kernel: %s; firmware: %s; microcode: %s' "${CFG_KERNEL_MODE:-$(T 'not selected')}" "$CFG_FIRMWARE" "$CFG_MICROCODE")"
    printf '%s\n' "$(T 'Kernel cmdline: %s' "${CFG_KERNEL_CMDLINE:-$(T 'empty')}")"
    printf '%s\n' "$(T 'Bootloader: %s' "$CFG_BOOTLOADER")"
    printf '\n%s\n' "$(T 'Host: %s; TZ: %s; locale: %s; keymap: %s; hwclock: %s' \
        "$CFG_HOSTNAME" "$CFG_TIMEZONE" "$CFG_LOCALE" "$CFG_KEYMAP" "$CFG_HWCLOCK")"
    printf '%s\n' "$(T 'Network: %s; SSH: %s; cron: %s; chrony: %s; syslog: %s; sudo: %s' \
        "$CFG_NETWORK" "$CFG_SSH" "$CFG_CRON" "$CFG_CHRONY" "$CFG_SYSLOG" "$CFG_SUDO")"
    printf '%s\n' "$(T 'User: %s (create: %s)' "$CFG_USERNAME" "$CFG_CREATE_USER")"
    printf '%s\n' "$(T 'Language: %s; target locale: %s' "$(i18n_language_label "${CFG_UI_LANGUAGE:-en}")" "$CFG_LOCALE")"
}

wizard_show_summary() {
    local tmp
    if ! config_validate; then
        local errors="" error
        for error in "${VALIDATION_ERRORS[@]}"; do
            errors+="• ${error}"$'\n'
        done
        ui_error "$(T 'Check the settings')" "$errors"
        return 1
    fi
    tmp=$(mktemp "${GI_WORKDIR}/summary.XXXXXX")
    wizard_summary_text >"$tmp"
    chmod 0600 -- "$tmp"
    ui_show_file "$(T 'Configuration summary')" "$tmp"
    rm -f -- "$tmp"
    return 0
}

wizard_load_config() {
    local path
    ui_input "$(T 'Load configuration')" "$(T 'Path to the configuration file:')" "$GI_CONFIG_FILE" \
        validate_nonempty "$(T 'File format: KEY="value"')" no || return 0
    path=$UI_RESULT
    if [[ ! -f $path ]]; then
        ui_error "$(T 'File not found')" "$path"
        return 0
    fi
    config_load "$path"
    GI_CONFIG_EXISTED=1
    GI_MODE_DEFAULTS_APPLIED=1
    case "${CFG_UI_LANGUAGE:-en}" in
        en|ru) ;;
        *)
            warn "$(T 'Unknown UI language "%s"; using English.' "$CFG_UI_LANGUAGE")"
            CFG_UI_LANGUAGE=en
            ;;
    esac
    i18n_init "$CFG_UI_LANGUAGE"
    config_derived
    # Secrets belong to one process and are never part of a configuration file.
    GI_ROOT_PASSWORD=""
    GI_USER_PASSWORD=""
    config_save
    ui_msg "$(T 'Configuration loaded')" \
        "$(T 'Settings were read from %s and saved to %s.\nPasswords must be entered again.' "$path" "$GI_CONFIG_FILE")"
}

wizard_about() {
    ui_header "$(T 'About')" "${GI_NAME} ${GI_VERSION}"
    ui_wrap "$(T 'Gentoo Linux installer with a console interface.\n\nSupported: UEFI+GPT and BIOS+MBR, OpenRC and systemd,\nbinary, compiled, automatic and manual kernels, GRUB,\noptional XFCE + LightDM and GNOME + GDM,\nEasy and Advanced configuration modes.\nNot supported: LUKS, LVM, RAID, Secure Boot signing and dual boot.\n\nThis project is distributed under the MIT license.\nLogs: %s\nState: %s' "$GI_LOG_DIR" "$GI_STATE_FILE")"
    ui_pause "$(T 'Enter - return')"
}

wizard_reset_state() {
    if ! ui_confirm "$(T 'Reset state')" \
        "$(T 'Delete the markers for completed steps? Configuration and disk data are not removed.')" no; then
        return 0
    fi
    chroot_unmount
    disks_unmount_all || warn "$(T 'failed to unmount the target partitions')"
    state_reset
    GI_ROOT_PASSWORD=""
    GI_USER_PASSWORD=""
    ui_msg "$(T 'State reset')" "$(T 'The next installation will start from the disk partitioning step.')"
}

wizard_main() {
    local choice
    local -a items=()
    while :; do
        items=()
        if ! state_is_done finalize; then
            if state_has_progress; then
                items+=("install|$(T 'Continue installation')|$(T 'Resume from the next unfinished step')")
            else
                items+=("install|$(T 'Configure and install')|$(T 'Collect all settings, confirm once, then install unattended')")
            fi
        fi
        if ((GI_EASY_MODE)); then
            items+=("mode|$(T 'Mode: Easy')|$(T 'Switch to Advanced mode')")
        else
            items+=("mode|$(T 'Mode: Advanced')|$(T 'Switch to Easy mode')")
        fi
        items+=(
            "summary|$(T 'Check configuration')|$(T 'Show the summary and validation errors')"
            "load|$(T 'Load configuration')|$(T 'Read a KEY="value" file')"
            "save|$(T 'Save configuration')|$(T 'Write the settings to %s' "$GI_CONFIG_FILE")"
            "language|$(T 'Language: %s' "$(i18n_language_label "${CFG_UI_LANGUAGE:-en}")")|$(T 'English or Russian interface')"
            "about|$(T 'About')|$(T 'Version, limitations, logs')"
            "shell|$(T 'Open a shell')|$(T 'Leave the installer without unmounting')"
        )
        state_has_progress && items+=("reset|$(T 'Reset state')|$(T 'Start the installation over')")
        items+=("exit|$(T 'Exit')|$(T 'Quit the installer')")
        ui_menu "$(T 'Main menu')" "$(T 'Review the settings first, then start the installation')" "" \
            "${items[@]}" || return 0
        choice=$UI_RESULT
        case "$choice" in
            install)
                if state_is_done finalize; then
                    ui_msg "$(T 'Installation already complete')" \
                        "$(T 'Reset the state if you want to install the system again.')"
                elif state_has_progress; then
                    main_start_installation || true
                else
                    if wizard_run_setup; then
                        main_start_installation || true
                    fi
                fi
                ;;
            mode) wizard_toggle_mode ;;
            summary) wizard_show_summary || true ;;
            load) wizard_load_config ;;
            save) ui_on_save ;;
            language) i18n_choose_language ;;
            about) wizard_about ;;
            shell) ui_interactive "$(T 'Shell (exit to return to the installer)')" /bin/bash -l ;;
            reset) wizard_reset_state ;;
            exit)
                if state_has_progress && ! state_is_done finalize; then
                    if ! ui_confirm "$(T 'Exit the installer')" \
                        "$(T 'The installation is not complete. Exit? State will be saved so you can continue later.')" no; then
                        continue
                    fi
                fi
                return 0
                ;;
        esac
    done
}
