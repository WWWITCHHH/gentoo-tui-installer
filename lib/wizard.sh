# shellcheck shell=bash
# Interactive configuration wizard.

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

wizard_edit_boot() {
    local choice
    ui_menu "$(T 'Boot mode')" \
        "$(T 'Current Minimal CD mode: %s' "$([[ -d /sys/firmware/efi ]] && printf UEFI || printf BIOS)")" \
        "$CFG_BOOT_MODE" \
        "uefi|UEFI + GPT|$(T 'ESP at /efi, GRUB bootloader (x86_64-efi)')" \
        "bios|BIOS + MBR|$(T '/boot partition, GRUB bootloader (i386-pc)')" || return 0
    choice=$UI_RESULT
    if [[ $choice != "$CFG_BOOT_MODE" ]]; then
        CFG_BOOT_MODE=$choice
        if [[ $choice == uefi ]]; then
            CFG_PART_BOOT=""
            CFG_UUID_BOOT=""
        else
            CFG_PART_ESP=""
            CFG_UUID_ESP=""
        fi
        wizard_save
    fi
    return 0
}

wizard_edit_disk_select() {
    local previous=$CFG_DISK
    disks_select_disk || return 0
    if [[ $CFG_DISK != "$previous" ]]; then
        CFG_PART_ESP="" CFG_PART_BOOT="" CFG_PART_SWAP="" CFG_PART_ROOT="" CFG_PART_HOME=""
        CFG_UUID_ESP="" CFG_UUID_BOOT="" CFG_UUID_SWAP="" CFG_UUID_ROOT="" CFG_UUID_HOME=""
    fi
    wizard_save
}

wizard_edit_swap() {
    local choice default max
    while :; do
        ui_menu "$(T 'Swap partition')" "$(T 'Swap can be omitted if there is enough RAM')" "$CFG_SWAP_MODE" \
            "auto|$(T 'Automatic')|$(T 'Gentoo Handbook table: 4-8 GiB depending on RAM')" \
            "none|$(T 'No swap')|$(T 'Do not create a swap partition')" \
            "custom|$(T 'Custom size')|$(T 'Specify the size in MiB')" || return 0
        choice=$UI_RESULT
        case "$choice" in
            auto|none)
                CFG_SWAP_MODE=$choice
                CFG_SWAP_MIB=0
                CFG_PART_SWAP=""
                CFG_UUID_SWAP=""
                CFG_FORMAT_SWAP=no
                wizard_save
                return 0
                ;;
            custom)
                max=1048576
                if [[ -n $CFG_DISK && -b $CFG_DISK ]]; then
                    max=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '1048576')
                fi
                default=$CFG_SWAP_MIB
                ((default > 0)) || default=$(suggest_swap_mib)
                if ui_int_input "$(T 'Swap size')" "$(T 'Enter the swap size in MiB:')" "$default" 1 "$max"; then
                    CFG_SWAP_MODE=custom
                    CFG_SWAP_MIB=$UI_RESULT
                    wizard_save
                    return 0
                fi
                ;;
        esac
    done
}

wizard_edit_home() {
    local choice default max
    while :; do
        ui_menu "$(T '/home partition')" "$(T 'A separate /home makes reinstalling easier')" "$CFG_HOME_MODE" \
            "no|$(T 'No separate /home')|$(T 'Home directories live on the root partition')" \
            "separate|$(T 'Separate /home')|$(T 'Create or use a dedicated partition')" || return 0
        choice=$UI_RESULT
        if [[ $choice == no ]]; then
            CFG_HOME_MODE=no
            CFG_HOME_MIB=0
            CFG_PART_HOME=""
            CFG_UUID_HOME=""
            CFG_FORMAT_HOME=no
            wizard_save
            return 0
        fi
        max=1048576
        if [[ -n $CFG_DISK && -b $CFG_DISK ]]; then
            max=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '1048576')
            ((max > 9216)) && max=$((max - 9216))
        fi
        ((max < 1024)) && max=1024
        default=$CFG_HOME_MIB
        ((default > 0)) || default=32768
        ((default > max)) && default=$max
        if ui_int_input "$(T '/home size')" "$(T 'Enter the /home size in MiB:')" "$default" 1024 "$max"; then
            CFG_HOME_MODE=separate
            CFG_HOME_MIB=$UI_RESULT
            wizard_save
            return 0
        fi
    done
}

wizard_edit_manual_layout() {
    if [[ -z $CFG_DISK || ! -b $CFG_DISK ]]; then
        disks_select_disk || return 0
    fi
    if disks_manual_assign; then
        CFG_DISK_MODE=manual
        wizard_save
        ui_msg "$(T 'Partitions assigned')" \
            "$(T 'Formatting and filesystem checks will be performed in the disk step.')"
    fi
}

wizard_edit_disk() {
    local choice
    if state_is_done disk; then
        ui_msg "$(T 'Disk already partitioned')" \
            "$(T 'Partitioning is complete. To change the disk or layout,\nreset the installation state in the main menu.')"
        return 0
    fi
    while :; do
        local plan_note
        plan_note=$(T 'Press "Start installation" after checking the settings')
        if [[ $CFG_DISK_MODE == auto && -n $CFG_DISK && -b $CFG_DISK ]]; then
            local disk_mib
            disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
            if disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" 2>/dev/null; then
                plan_note=$(T 'Plan: %s' "$(disk_plan_summary)")
            else
                plan_note=$(T 'Plan: error - %s' "$PLAN_ERROR")
            fi
        fi
        ui_menu "$(T 'Disk and partitioning')" "$plan_note" "" \
            "mode|$(T 'Mode: %s' "$CFG_DISK_MODE")|$(T 'auto - automatic layout, manual - your own partitions')" \
            "disk|$(T 'Target disk: %s' "${CFG_DISK:-$(T 'not selected')}")|$(T 'Choose the installation disk')" \
            "boot|$(T 'Boot mode: %s' "$CFG_BOOT_MODE")|$(T 'UEFI+GPT or BIOS+MBR')" \
            "rootfs|$(T 'Root filesystem: %s' "$CFG_ROOT_FS")|$(T 'xfs, ext4 or btrfs')" \
            "homefs|$(T '/home filesystem: %s' "$CFG_HOME_FS")|$(T 'Used for a separate /home')" \
            "swap|$(T 'Swap: %s' "$CFG_SWAP_MODE")|$(T 'Automatic, none or a custom size')" \
            "home|$(T '/home: %s' "$CFG_HOME_MODE")|$(T 'Separate partition or part of root')" \
            "manual|$(T 'Assign partitions manually')|$(T 'For manual mode: choose existing partitions')" \
            "back|$(T 'Back')|$(T 'Return to the main menu')" || return 0
        choice=$UI_RESULT
        case "$choice" in
            mode)
                if ui_menu "$(T 'Partitioning mode')" \
                    "$(T 'The automatic layout destroys the partition table')" "$CFG_DISK_MODE" \
                    "auto|$(T 'Automatic')|$(T 'Create GPT/MBR and partitions according to the plan')" \
                    "manual|$(T 'Manual')|$(T 'Use partitions that already exist')"; then
                    if [[ $UI_RESULT != "$CFG_DISK_MODE" ]]; then
                        CFG_DISK_MODE=$UI_RESULT
                        CFG_PART_ESP="" CFG_PART_BOOT="" CFG_PART_SWAP="" CFG_PART_ROOT="" CFG_PART_HOME=""
                        CFG_UUID_ESP="" CFG_UUID_BOOT="" CFG_UUID_SWAP="" CFG_UUID_ROOT="" CFG_UUID_HOME=""
                    fi
                    wizard_save
                fi
                ;;
            disk) wizard_edit_disk_select ;;
            boot) wizard_edit_boot ;;
            rootfs) wizard_choose_fs "$(T 'Root filesystem')" "$CFG_ROOT_FS" && { CFG_ROOT_FS=$UI_RESULT; wizard_save; } ;;
            homefs) wizard_choose_fs "$(T '/home filesystem')" "$CFG_HOME_FS" && { CFG_HOME_FS=$UI_RESULT; wizard_save; } ;;
            swap) wizard_edit_swap ;;
            home) wizard_edit_home ;;
            manual) wizard_edit_manual_layout ;;
            back) return 0 ;;
        esac
    done
}

disk_plan_summary() {
    local i first=yes out=""
    for ((i = 0; i < PLAN_COUNT; i++)); do
        [[ $first == yes ]] && first=no || out+=", "
        out+="${PLAN_LABEL[$i]} $(human_mib "${PLAN_SIZE[$i]}")"
    done
    printf '%s' "$out"
}

wizard_edit_stage() {
    local choice value
    wizard_step_locked portage "$(T 'Stage3 and Portage')" || return 0
    while :; do
        ui_menu "$(T 'Stage3 and Portage')" "$(T 'Stage3 download and package build settings')" "" \
            "flavor|$(T 'Stage3: %s' "$CFG_STAGE_FLAVOR")|$(T 'openrc/systemd and desktop variants')" \
            "mirror|$(T 'Mirror: %s' "$CFG_MIRROR")|$(T 'Base distfiles.gentoo.org URL')" \
            "stageurl|$(T 'Direct Stage3 URL: %s' "${CFG_STAGE_URL:-$(T 'automatic')}")|$(T 'Empty - use latest-stage3')" \
            "profile|$(T 'Profile: %s' "$CFG_PROFILE")|$(T 'stage, desktop, gnome, kde, hardened; kept in sync with DESKTOP')" \
            "cpu|$(T 'CPU_FLAGS_X86: %s' "$CFG_CPU_FLAGS")|$(T 'Detect with cpuid2cpuflags')" \
            "world|$(T 'Update @world: %s' "$CFG_UPDATE_WORLD")|$(T 'Can take a long time')" \
            "jobs|$(T 'MAKEOPTS: %s' "$CFG_MAKE_JOBS")|$(T 'Number of parallel build jobs')" \
            "cflags|$(T 'CFLAGS: %s' "$CFG_CFLAGS")|$(T 'Compiler flags')" \
            "video|$(T 'VIDEO_CARDS: %s' "${CFG_VIDEO_CARDS:-$(T 'not set')}")|$(T 'GPU drivers for Portage')" \
            "use|$(T 'Extra USE: %s' "${CFG_USE_EXTRA:-$(T 'none')}")|$(T 'Additional USE flags')" \
            "back|$(T 'Back')|$(T 'Return')" || return 0
        choice=$UI_RESULT
        case "$choice" in
            flavor)
                if state_is_done stage3; then
                    ui_msg "$(T 'Stage3 already installed')" \
                        "$(T 'The Stage3 variant cannot be changed after extraction.\nReset the state if you need a different variant.')"
                elif ui_menu "$(T 'Stage3 variant')" "$(T 'Choose the init system and software set')" "$CFG_STAGE_FLAVOR" \
                    "openrc|OpenRC|$(T 'Classic Gentoo, minimal Stage3')" \
                    "systemd|systemd|$(T 'Stage3 with systemd')" \
                    "desktop-openrc|Desktop OpenRC|$(T 'Stage3 with graphical libraries')" \
                    "desktop-systemd|Desktop systemd|$(T 'Stage3 with graphics and systemd')"; then
                    CFG_STAGE_FLAVOR=$UI_RESULT
                    config_derived
                    wizard_save
                fi
                ;;
            mirror)
                ui_input "$(T 'distfiles mirror')" "$(T 'Mirror base URL:')" "$CFG_MIRROR" validate_url \
                    "$(T 'For example: https://distfiles.gentoo.org')" no &&
                    { CFG_MIRROR=${UI_RESULT%/}; wizard_save; }
                ;;
            stageurl)
                ui_input "$(T 'Direct Stage3 URL')" "$(T 'Leave empty for automatic selection:')" \
                    "$CFG_STAGE_URL" validate_optional_url "$(T 'Full URL to the .tar.xz file')" no &&
                    { CFG_STAGE_URL=$UI_RESULT; wizard_save; }
                ;;
            profile)
                if ui_menu "$(T 'Portage profile')" "$(T 'The profile controls USE flags and the package set')" "$CFG_PROFILE" \
                    "stage|Stage|$(T 'Base profile without a desktop')" \
                    "desktop|Desktop|$(T 'Desktop profile')" \
                    "gnome|GNOME|$(T 'Desktop + GNOME')" \
                    "kde|KDE Plasma|$(T 'Desktop + KDE')" \
                    "hardened|Hardened|$(T 'Additional hardening')"; then
                    CFG_PROFILE=$UI_RESULT
                    wizard_save
                fi
                ;;
            cpu)
                CFG_CPU_FLAGS=$(wizard_bool "$(T 'CPU_FLAGS_X86')" \
                    "$(T 'Detect CPU flags with cpuid2cpuflags?')" "$CFG_CPU_FLAGS")
                wizard_save
                ;;
            world)
                CFG_UPDATE_WORLD=$(wizard_bool "$(T 'Update @world')" \
                    "$(T 'Run emerge --update --deep --newuse @world? This can take a long time.')" "$CFG_UPDATE_WORLD" no)
                wizard_save
                ;;
            jobs)
                if ui_menu "$(T 'MAKEOPTS')" "$(T 'Number of parallel build jobs')" "$CFG_MAKE_JOBS" \
                    "auto|$(T 'Automatic')|$(T 'Based on CPU and RAM: %s' "$(make_jobs_suggestion)")" \
                    "custom|$(T 'Specify a number')|$(T 'Enter it manually')"; then
                    if [[ $UI_RESULT == custom ]]; then
                        value=$(make_jobs_suggestion)
                        ui_int_input "$(T 'MAKEOPTS')" "$(T 'Number of make jobs:')" "$value" 1 256 &&
                            { CFG_MAKE_JOBS=$UI_RESULT; wizard_save; }
                    else
                        CFG_MAKE_JOBS=auto
                        wizard_save
                    fi
                fi
                ;;
            cflags)
                ui_input "$(T 'CFLAGS')" "$(T 'Compiler flags:')" "$CFG_CFLAGS" validate_cflags \
                    "$(T 'Usually: -march=native -O2 -pipe')" no &&
                    { CFG_CFLAGS=$UI_RESULT; wizard_save; }
                ;;
            video)
                ui_input "$(T 'VIDEO_CARDS')" "$(T 'Video drivers (space-separated, may be empty):')" \
                    "$CFG_VIDEO_CARDS" validate_optional_tokens \
                    "$(T 'For example: amdgpu radeonsi or intel')" no &&
                    { CFG_VIDEO_CARDS=$UI_RESULT; wizard_save; }
                ;;
            use)
                ui_input "$(T 'USE flags')" "$(T 'Additional USE flags (space-separated):')" "$CFG_USE_EXTRA" \
                    validate_use_flags "$(T 'For example: cups bluetooth')" no &&
                    { CFG_USE_EXTRA=$UI_RESULT; wizard_save; }
                ;;
            back) return 0 ;;
        esac
    done
}

wizard_edit_kernel() {
    local choice
    wizard_step_locked kernel "$(T 'Kernel and bootloader')" || return 0
    while :; do
        ui_menu "$(T 'Kernel and bootloader')" "$(T 'Kernel installation settings')" "" \
            "mode|$(T 'Method: %s' "$CFG_KERNEL_MODE")|$(T 'bin, dist or manual')" \
            "firmware|$(T 'linux-firmware: %s' "$CFG_FIRMWARE")|$(T 'Needed for Wi-Fi, GPUs and more')" \
            "microcode|$(T 'CPU microcode: %s' "$CFG_MICROCODE")|$(T 'auto, none, intel or amd')" \
            "cmdline|$(T 'Kernel cmdline: %s' "${CFG_KERNEL_CMDLINE:-$(T 'empty')}")|$(T 'Additional kernel parameters')" \
            "boot|$(T 'Bootloader: %s' "$CFG_BOOTLOADER")|$(T 'Only GRUB is supported in this version')" \
            "back|$(T 'Back')|$(T 'Return')" || return 0
        choice=$UI_RESULT
        case "$choice" in
            mode)
                if ui_menu "$(T 'Kernel installation method')" "$(T 'Choose how to obtain the kernel')" "$CFG_KERNEL_MODE" \
                    "bin|gentoo-kernel-bin|$(T 'Prebuilt binary kernel, fast')" \
                    "dist|gentoo-kernel|$(T 'Build with the Gentoo configuration')" \
                    "manual|gentoo-sources|$(T 'Manual configuration with menuconfig')"; then
                    CFG_KERNEL_MODE=$UI_RESULT
                    wizard_save
                fi
                ;;
            firmware)
                CFG_FIRMWARE=$(wizard_bool "$(T 'Device firmware')" \
                    "$(T 'Install sys-kernel/linux-firmware? The package is large.')" "$CFG_FIRMWARE")
                wizard_save
                ;;
            microcode)
                if ui_menu "$(T 'CPU microcode')" "$(T 'Microcode updates are loaded at boot')" "$CFG_MICROCODE" \
                    "auto|$(T 'Automatic')|$(T 'Detect the CPU vendor')" \
                    "none|$(T 'Do not install')|" \
                    "intel|Intel|sys-firmware/intel-microcode" \
                    "amd|AMD|sys-firmware/amd-ucode"; then
                    CFG_MICROCODE=$UI_RESULT
                    wizard_save
                fi
                ;;
            cmdline)
                ui_input "$(T 'Kernel cmdline')" "$(T 'Additional parameters (root is added automatically):')" \
                    "$CFG_KERNEL_CMDLINE" validate_kernel_cmdline "$(T 'For example: quiet splash')" no &&
                    { CFG_KERNEL_CMDLINE=$UI_RESULT; wizard_save; }
                ;;
            boot)
                ui_msg "$(T 'Bootloader')" "$(T 'This version supports GRUB for UEFI and BIOS only.')"
                ;;
            back) return 0 ;;
        esac
    done
}

wizard_edit_desktop() {
    local choice old_profile
    if state_is_done desktop; then
        ui_msg "$(T 'Step already completed')" \
            "$(T 'The desktop environment is already installed. To change the choice,\nreset the installation state in the main menu.')"
        return 0
    fi
    old_profile=$CFG_PROFILE
    if ! ui_menu "$(T 'Desktop environment')" \
        "$(T 'XFCE or GNOME; the Portage profile follows the choice')" "$CFG_DESKTOP" \
        "none|$(T 'No desktop environment')|$(T 'Install a console-only system')" \
        "xfce|XFCE + LightDM|$(T 'Lightweight desktop for everyday use')" \
        "gnome|GNOME + GDM|$(T 'Full GNOME environment; many packages')"; then
        return 0
    fi
    choice=$UI_RESULT
    CFG_DESKTOP=$choice
    config_derived
    wizard_save
    if [[ $CFG_PROFILE != "$old_profile" ]] && state_is_done portage; then
        ui_msg "$(T 'Profile changed after Portage')" \
            "$(T 'Portage is already complete, so the new profile %s will not be\napplied to the installed system. The desktop will be installed with the\ncurrent profile. Reset the state and start over to change the profile.' "$CFG_PROFILE")"
    fi
    if [[ $choice != none && -z $CFG_VIDEO_CARDS ]]; then
        ui_msg "$(T 'VIDEO_CARDS is not set')" \
            "$(T 'For hardware acceleration, specify GPU drivers under\n"Stage3 and Portage -> VIDEO_CARDS". Without VIDEO_CARDS, Xorg may\nonly use a basic mode.')"
    fi
}

wizard_edit_system() {
    local choice
    wizard_step_locked system "$(T 'System')" || return 0
    while :; do
        ui_menu "$(T 'System')" "$(T 'Hostname, time, locale and console')" "" \
            "hostname|$(T 'Hostname: %s' "$CFG_HOSTNAME")|" \
            "timezone|$(T 'Timezone: %s' "$CFG_TIMEZONE")|" \
            "locale|$(T 'Locale: %s' "$CFG_LOCALE")|" \
            "keymap|$(T 'Console keymap: %s' "$CFG_KEYMAP")|" \
            "hwclock|$(T 'Hardware clock: %s' "$CFG_HWCLOCK")|$(T 'UTC or local')" \
            "back|$(T 'Back')|$(T 'Return')" || return 0
        choice=$UI_RESULT
        case "$choice" in
            hostname)
                ui_input "$(T 'Hostname')" "$(T 'Enter the hostname:')" "$CFG_HOSTNAME" validate_hostname \
                    "$(T 'Latin letters, digits, dots and hyphens')" no &&
                    { CFG_HOSTNAME=$UI_RESULT; wizard_save; }
                ;;
            timezone)
                ui_input "$(T 'Timezone')" "$(T 'Enter the IANA zone:')" "$CFG_TIMEZONE" validate_timezone \
                    "$(T 'For example: Europe/Moscow or UTC')" no &&
                    { CFG_TIMEZONE=$UI_RESULT; wizard_save; }
                ;;
            locale)
                ui_input "$(T 'Locale')" "$(T 'Enter a UTF-8 locale:')" "$CFG_LOCALE" validate_locale \
                    "$(T 'For example: ru_RU.UTF-8 or en_US.UTF-8')" no &&
                    { CFG_LOCALE=$UI_RESULT; wizard_save; }
                ;;
            keymap)
                ui_input "$(T 'Console keymap')" "$(T 'Enter the keymap:')" "$CFG_KEYMAP" validate_keymap \
                    "$(T 'For example: us or ru')" no &&
                    { CFG_KEYMAP=$UI_RESULT; wizard_save; }
                ;;
            hwclock)
                if ui_menu "$(T 'Hardware clock')" "$(T 'How time is stored in the RTC')" "$CFG_HWCLOCK" \
                    "UTC|UTC|$(T 'Recommended, especially for dual boot')" \
                    "local|Local|$(T 'Local time')"; then
                    CFG_HWCLOCK=$UI_RESULT
                    wizard_save
                fi
                ;;
            back) return 0 ;;
        esac
    done
}

wizard_edit_services() {
    local choice
    wizard_step_locked tools "$(T 'Services and users')" || return 0
    while :; do
        ui_menu "$(T 'Services and users')" "$(T 'Network, SSH, logging and accounts')" "" \
            "network|$(T 'Network: %s' "$CFG_NETWORK")|$(T 'dhcpcd, NetworkManager or no configuration')" \
            "ssh|$(T 'SSH server: %s' "$CFG_SSH")|net-misc/openssh" \
            "cron|$(T 'Cron: %s' "$CFG_CRON")|sys-process/cronie" \
            "chrony|$(T 'Time sync: %s' "$CFG_CHRONY")|net-misc/chrony" \
            "syslog|$(T 'System log: %s' "$CFG_SYSLOG")|$(T 'sysklogd or rsyslog')" \
            "sudo|$(T 'Install sudo: %s' "$CFG_SUDO")|$(T 'Rule for the wheel group')" \
            "createuser|$(T 'Create user: %s' "$CFG_CREATE_USER")|$(T 'The password is requested in the system step')" \
            "username|$(T 'Username: %s' "$CFG_USERNAME")|" \
            "back|$(T 'Back')|$(T 'Return')" || return 0
        choice=$UI_RESULT
        case "$choice" in
            network)
                if ui_menu "$(T 'Network configuration')" "$(T 'Automatic configuration over DHCP')" "$CFG_NETWORK" \
                    "dhcpcd|dhcpcd|$(T 'Simple DHCP client')" \
                    "networkmanager|NetworkManager|$(T 'Convenient for Wi-Fi and desktops')" \
                    "none|$(T 'No configuration')|$(T 'Configure networking manually after installation')"; then
                    CFG_NETWORK=$UI_RESULT
                    wizard_save
                fi
                ;;
            ssh) CFG_SSH=$(wizard_bool "$(T 'SSH server')" "$(T 'Install and enable OpenSSH?')" "$CFG_SSH" no); wizard_save ;;
            cron) CFG_CRON=$(wizard_bool "$(T 'Cron')" "$(T 'Install and enable cronie?')" "$CFG_CRON"); wizard_save ;;
            chrony) CFG_CHRONY=$(wizard_bool "$(T 'Chrony')" "$(T 'Install and enable time synchronization?')" "$CFG_CHRONY"); wizard_save ;;
            syslog) CFG_SYSLOG=$(wizard_bool "$(T 'System log')" "$(T 'Install sysklogd/rsyslog?')" "$CFG_SYSLOG"); wizard_save ;;
            sudo) CFG_SUDO=$(wizard_bool "$(T 'sudo')" "$(T 'Install sudo and allow the wheel group?')" "$CFG_SUDO"); wizard_save ;;
            createuser)
                CFG_CREATE_USER=$(wizard_bool "$(T 'User account')" "$(T 'Create a regular user?')" "$CFG_CREATE_USER")
                wizard_save
                ;;
            username)
                ui_input "$(T 'Username')" "$(T 'Enter the username:')" "$CFG_USERNAME" validate_username \
                    "$(T 'Lowercase Latin letters, digits, _ and -')" no &&
                    { CFG_USERNAME=$UI_RESULT; wizard_save; }
                ;;
            back) return 0 ;;
        esac
    done
}

wizard_update_summary() {
    local step done=0 disk size fs progress boot
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
    progress="$done/${#STATE_STEPS[@]}"
    UI_MENU_SUMMARY=(
        "$(T 'Boot: %s · Disk: %s · FS: %s' "$boot" "$disk" "$fs")"
        "$(T 'Stage3: %s · Kernel: %s · Desktop: %s' "$CFG_STAGE_FLAVOR" "$CFG_KERNEL_MODE" "$(desktop_label)")"
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
    printf '\n%s\n' "$(T 'Kernel: %s; firmware: %s; microcode: %s' "$CFG_KERNEL_MODE" "$CFG_FIRMWARE" "$CFG_MICROCODE")"
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
        local errors=""
        local error
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
    case "${CFG_UI_LANGUAGE:-en}" in
        en|ru) ;;
        *)
            warn "$(T 'Unknown UI language "%s"; using English.' "$CFG_UI_LANGUAGE")"
            CFG_UI_LANGUAGE=en
            ;;
    esac
    i18n_init "$CFG_UI_LANGUAGE"
    config_derived
    config_save
    ui_msg "$(T 'Configuration loaded')" \
        "$(T 'Settings were read from %s and saved to %s.' "$path" "$GI_CONFIG_FILE")"
}

wizard_about() {
    ui_header "$(T 'About')" "${GI_NAME} ${GI_VERSION}"
    ui_wrap "$(T 'Gentoo Linux installer with a console interface.\n\nSupported: UEFI+GPT and BIOS+MBR, OpenRC and systemd,\nbinary, distribution and manual kernels, GRUB,\noptional XFCE + LightDM and GNOME + GDM.\nNot supported: LUKS, LVM, RAID, Secure Boot signing and dual boot.\n\nThis project is distributed under the MIT license.\nLogs: %s\nState: %s' "$GI_LOG_DIR" "$GI_STATE_FILE")"
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
    ui_msg "$(T 'State reset')" "$(T 'The next installation will start from the disk partitioning step.')"
}

wizard_main() {
    local choice
    local -a items=()
    while :; do
        local resume_note
        resume_note=$(T 'New installation')
        state_has_progress && resume_note=$(T 'Completed steps found; installation will continue from where it stopped')
        items=(
            "install|$(T 'Start / continue installation')|${resume_note}"
            "disk|$(T 'Disk and partitioning')|$(T 'Mode, disk, filesystems, swap and /home')"
            "stage|$(T 'Stage3 and Portage')|$(T 'Mirror, profile, CFLAGS, USE, MAKEOPTS')"
            "kernel|$(T 'Kernel and bootloader')|$(T 'Binary, distribution or manual kernel')"
            "system|$(T 'System')|$(T 'Hostname, time, locale, keymap, clock')"
            "services|$(T 'Services and users')|$(T 'Network, SSH, cron, chrony, syslog, sudo')"
            "desktop|$(T 'Desktop environment')|$(T 'XFCE, GNOME or no desktop')"
            "language|$(T 'Language: %s' "$(i18n_language_label "${CFG_UI_LANGUAGE:-en}")")|$(T 'English or Russian interface')"
            "summary|$(T 'Check configuration')|$(T 'Show the summary and validation errors')"
            "load|$(T 'Load configuration')|$(T 'Read a KEY="value" file')"
            "save|$(T 'Save configuration')|$(T 'Write the settings to %s' "$GI_CONFIG_FILE")"
            "shell|$(T 'Open a shell')|$(T 'Leave the installer without unmounting')"
            "about|$(T 'About')|$(T 'Version, limitations, logs')"
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
                else
                    main_start_installation || true
                fi
                ;;
            disk) wizard_edit_disk ;;
            stage) wizard_edit_stage ;;
            kernel) wizard_edit_kernel ;;
            system) wizard_edit_system ;;
            services) wizard_edit_services ;;
            desktop) wizard_edit_desktop ;;
            language) i18n_choose_language ;;
            summary) wizard_show_summary || true ;;
            load) wizard_load_config ;;
            save) ui_on_save ;;
            shell) ui_interactive "$(T 'Shell (exit to return to the installer)')" /bin/bash -l ;;
            about) wizard_about ;;
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
