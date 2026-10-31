# shellcheck shell=bash
# Entry point logic: CLI, resumes, step orchestration.

GI_CONFIG_EXPLICIT=0
GI_LANG_REQUEST=""
GI_LANG_GIVEN=0

main_usage() {
    cat <<EOF
${GI_NAME} ${GI_VERSION}

Usage: gentoo-installer [options]

Options:
  -c, --config FILE   use the specified configuration file
      --lang LANG     interface language: en (default) or ru
  -r, --resume        continue from the saved state immediately
  -y, --yes           skip the destructive-action warning and the disk
                      confirmation (passwords and interactive questions remain)
      --debug         write debug messages to stderr
  -h, --help          show this help
  -V, --version       show the version

The installer must be started as root from the Gentoo Minimal Installation CD.
Logs: ${GI_LOG_DIR}
EOF
}

main_parse_args() {
    while (($#)); do
        case "$1" in
            -h|--help)
                main_usage
                exit 0
                ;;
            -V|--version)
                printf '%s %s\n' "$GI_NAME" "$GI_VERSION"
                [[ -n ${GI_GIT_VERSION:-} ]] && printf 'git: %s\n' "$GI_GIT_VERSION"
                exit 0
                ;;
            -c|--config)
                (($# >= 2)) || die "$(T 'option %s requires a file path' "$1")"
                GI_CONFIG_FILE=$2
                GI_CONFIG_EXPLICIT=1
                shift
                ;;
            --lang)
                (($# >= 2)) || die "$(T 'option %s requires a language (en or ru)' "$1")"
                case "$2" in
                    en|ru) ;;
                    *) die "$(T 'unsupported language: %s (use en or ru)' "$2")" ;;
                esac
                GI_LANG_REQUEST=$2
                GI_LANG_GIVEN=1
                shift
                ;;
            -r|--resume)
                GI_RESUME=1
                ;;
            -y|--yes)
                GI_ASSUME_YES=1
                ;;
            --debug)
                GI_DEBUG=1
                ;;
            *)
                die "$(T 'unknown option: %s (see --help)' "$1")"
                ;;
        esac
        shift
    done

    if ((GI_CONFIG_EXPLICIT)); then
        if [[ $GI_CONFIG_FILE != /* ]]; then
            GI_CONFIG_FILE="$(readlink -m -- "$GI_CONFIG_FILE")"
        fi
        [[ -f $GI_CONFIG_FILE ]] || die "$(T 'configuration file not found: %s' "$GI_CONFIG_FILE")"
    fi
    if ((GI_RESUME)) && [[ ! -f $GI_CONFIG_FILE ]]; then
        die "$(T '--resume requires a saved configuration file: %s' "$GI_CONFIG_FILE")"
    fi
}

state_step_index() {
    local step=$1 i
    for i in "${!STATE_STEPS[@]}"; do
        if [[ ${STATE_STEPS[$i]} == "$step" ]]; then
            printf '%d' "$((i + 1))"
            return 0
        fi
    done
    printf '0'
}

step_description() {
    case "$1" in
        disk) T 'Create partitions and filesystems, then mount the target system.' ;;
        stage3) T 'Download, verify and extract Stage3, then install Portage.' ;;
        portage) T 'Copy resolv.conf, enter the chroot, write make.conf, sync and select a profile.' ;;
        kernel) T 'Firmware, microcode and kernel: gentoo-kernel-bin, gentoo-kernel or gentoo-sources.' ;;
        system) T 'Hostname, time, locale, keymap, fstab, root password and user account.' ;;
        tools) T 'Network, SSH, cron, chrony, system logging, sudo and gentoolkit.' ;;
        bootloader) T 'Install GRUB into the ESP or MBR and generate grub.cfg.' ;;
        desktop) T 'Xorg, XFCE + LightDM or GNOME + GDM; skipped when DESKTOP=none.' ;;
        finalize) T 'depclean, remove temporary files and unmount everything.' ;;
        *) printf '%s' "$1" ;;
    esac
}

main_banner() {
    ui_header "" ""
    printf '  %s%s %s%s\n' "$C_BOLD$C_CYAN" "$GI_NAME" "$GI_VERSION" "$C_RESET"
    ui_wrap "$(T 'Git: %s' "${GI_GIT_VERSION:-$(T 'unavailable')}")"
    printf '\n'
    ui_wrap "$(T 'The installer collects all settings in grouped pages first. After one final confirmation it installs Gentoo without asking between steps:\npartitioning -> Stage3 -> Portage -> kernel -> system -> services -> GRUB\n-> desktop environment -> finish.')"
    printf '\n'
    ui_wrap "$(T 'Configuration file: %s\nWorking directory:   %s\nLog:                 %s' \
        "$GI_CONFIG_FILE" "$GI_WORKDIR" "$GI_LOG_FILE")"
    if state_has_progress; then
        printf '\n'
        ui_wrap "$(T 'Saved state found. Completed steps will be skipped.')"
    fi
    ui_footer "$(T 'Enter - open the menu')"
    ui_read_key || true
}

main_resume_prompt() {
    if state_is_done finalize; then
        ui_msg "$(T 'Installation already complete')" \
            "$(T 'The state of the last installation is saved. To start over, choose\n"Reset state" in the main menu.')"
        return 0
    fi
    if ! state_has_progress; then
        return 0
    fi
    if ui_confirm "$(T 'Unfinished installation')" \
        "$(T 'Completed steps were found. Continue the installation from where it stopped?')" yes; then
        log_info "resuming existing installation"
        return 0
    fi
    chroot_unmount
    state_reset
    disks_unmount_all || warn "$(T 'failed to unmount partitions')"
    ui_msg "$(T 'Starting over')" "$(T 'State has been reset. Configuration values are preserved.')"
    log_info "state reset by user"
}

main_show_validation_errors() {
    local error text=""
    for error in "${VALIDATION_ERRORS[@]}"; do
        text+="• ${error}"$'\n'
    done
    ui_error "$(T 'Check the installation settings')" "$text"
}

main_start_installation() {
    local confirmed=${GI_INSTALL_CONFIRMED:-0}
    if state_is_done finalize; then
        ui_msg "$(T 'Installation already complete')" \
            "$(T 'Reset the state to install the system again.')"
        return 1
    fi
    # The review page sets GI_UNATTENDED together with GI_INSTALL_CONFIRMED.
    # Keep the pre-installation checks interactive and re-enable unattended mode
    # only right before installation_run.
    GI_UNATTENDED=0

    if ! state_has_progress && ((!GI_ASSUME_YES)) && ((!confirmed)); then
        preflight_install_media_warning || return 1
    fi
    if ! preflight_run; then
        if ((PREFLIGHT_FAILED)); then
            ui_error "$(T 'Environment check failed')" \
                "$(T 'Fix the problems marked in red and try again.')"
        fi
        return 1
    fi
    # The confirmation belongs to this single start attempt. A failed install
    # must ask again when it is retried from the main menu.
    GI_INSTALL_CONFIRMED=0

    if ! state_is_done system; then
        wizard_ensure_passwords || return 1
    fi

    if [[ $CFG_DISK_MODE == auto ]]; then
        if [[ -z $CFG_DISK || ! -b $CFG_DISK ]]; then
            disks_select_disk || return 1
        fi
    elif [[ -z $CFG_PART_ROOT || ! -b $CFG_PART_ROOT ]]; then
        ui_msg "$(T 'Manual partitioning')" \
            "$(T 'Assign partitions for root, ESP/boot, swap and /home.')"
        disks_manual_assign || return 1
    fi
    if [[ $CFG_DISK_MODE == manual ]] && ! state_is_done disk && ((!GI_MANUAL_OPTIONS_READY)); then
        disks_manual_options || return 1
        GI_MANUAL_OPTIONS_READY=1
    fi

    config_derived
    if ! config_validate; then
        main_show_validation_errors
        return 1
    fi
    config_save

    if ((GI_ASSUME_YES)); then
        # --yes skips the interactive warning, but the warnings still belong in
        # the log for post-install troubleshooting.
        config_check_consistency || true
        local warning
        for warning in "${CONFIG_WARNINGS[@]}"; do
            log_warn "configuration: $warning"
        done
    fi

    if ((!GI_ASSUME_YES)) && ((!confirmed)); then
        if ! wizard_confirm_installation; then
            return 1
        fi
    fi

    GI_STEP_TOTAL=${#STATE_STEPS[@]}
    GI_STEP_INDEX=0
    GI_UNATTENDED=1
    log_info "installation started (unattended)"
    local status=0
    installation_run || status=$?
    GI_UNATTENDED=0
    return "$status"
}

installation_run() {
    local step func index
    if state_is_done disk; then
        log_info "restoring mounts for an already partitioned system"
        if ! disks_mount_all; then
            ui_error "$(T 'Failed to mount')" \
                "$(T 'Check the disk connection and partition settings.')"
            return 1
        fi
    fi

    for step in "${STATE_STEPS[@]}"; do
        if state_is_done "$step"; then
            log_info "step skipped (already done): $step"
            continue
        fi
        index=$(state_step_index "$step")
        GI_STEP_INDEX=$index
        GI_CURRENT_STEP=$step
        ui_step_intro "$index" "$GI_STEP_TOTAL" "$(state_label "$step")" "$(step_description "$step")"
        func="step_${step}"
        if "$func"; then
            state_mark_done "$step"
            log_info "step completed: $step"
        else
            GI_CURRENT_STEP=""
            log_error "step failed: $step"
            ui_error "$(T 'Step not completed')" \
                "$(T 'The step "%s" did not complete. Fix the problem and choose\n"Start / continue installation"; completed steps will be skipped.' \
                    "$(state_label "$step")")"
            return 1
        fi
    done
    GI_CURRENT_STEP=""
    GI_STEP_INDEX=$GI_STEP_TOTAL
    log_info "installation completed"
    return 0
}

main_on_signal() {
    trap - INT TERM HUP
    ui_cleanup
    log_warn "installer interrupted by signal"
    printf '\n%s\n' "$(T 'Installer interrupted. State is saved; run it again to continue.')"
    printf '%s\n' "$(T 'Log: %s' "$GI_LOG_FILE")"
    exit 130
}

main() {
    local config_existed=0
    main_parse_args "$@"
    if [[ ! -t 0 || ! -t 1 ]]; then
        die "$(T 'the installer needs an interactive terminal (stdin and stdout)')"
    fi
    require_root
    init_workdir
    config_defaults

    if [[ -f $GI_CONFIG_FILE ]]; then
        config_existed=1
        config_load "$GI_CONFIG_FILE"
    elif ((GI_CONFIG_EXPLICIT)); then
        die "$(T 'configuration file not found: %s' "$GI_CONFIG_FILE")"
    fi

    if ((GI_LANG_GIVEN)); then
        CFG_UI_LANGUAGE=$GI_LANG_REQUEST
    fi
    case "${CFG_UI_LANGUAGE:-en}" in
        en|ru) ;;
        *)
            warn "$(T 'Unknown UI language "%s"; using English.' "$CFG_UI_LANGUAGE")"
            CFG_UI_LANGUAGE=en
            ;;
    esac
    i18n_init "$CFG_UI_LANGUAGE"
    config_derived
    # A new installation gets a sensible VIDEO_CARDS default from the GPU that
    # is visible to the live environment. A loaded configuration keeps its
    # explicit value (including an empty one).
    if ((!config_existed)) && [[ -z $CFG_VIDEO_CARDS ]]; then
        CFG_VIDEO_CARDS=$(hardware_detect_video_cards)
        [[ -n $CFG_VIDEO_CARDS ]] && log_info "detected VIDEO_CARDS: $CFG_VIDEO_CARDS"
    fi
    state_load

    log_info "config file: $GI_CONFIG_FILE"
    log_info "state file: $GI_STATE_FILE"
    if ((GI_ASSUME_YES)); then
        log_warn "assume-yes mode enabled"
    fi

    trap main_on_signal INT TERM HUP
    ui_init

    # First run without an explicit choice: ask for the interface language
    # before showing the banner. Later changes are available in the main menu.
    if ((!config_existed && !GI_LANG_GIVEN)); then
        i18n_choose_language
        config_derived
        config_save
    elif ((GI_LANG_GIVEN)); then
        config_save
    fi
    log_info "UI language: $CFG_UI_LANGUAGE ($GI_UI_LOCALE)"

    main_banner

    if ((GI_RESUME)); then
        if state_is_done finalize; then
            ui_cleanup
            printf '\n%s\n' "$(T 'Installation is already complete. Reset the state to install again.')"
            printf '%s\n' "$(T 'Log: %s' "$GI_LOG_FILE")"
            return 0
        fi
        if ! main_start_installation; then
            ui_cleanup
            return 1
        fi
        ui_cleanup
        return 0
    fi

    main_resume_prompt
    wizard_main
    ui_cleanup
    printf '\n%s\n' "$(T 'Installation log: %s' "$GI_LOG_FILE")"
    if state_is_done finalize; then
        printf '%s\n' "$(T 'Installation complete. Reboot and remove the installation media.')"
    else
        printf '%s\n' "$(T 'To continue, run: %s --resume' "$GI_SCRIPT_DIR/gentoo-installer")"
    fi
    return 0
}
