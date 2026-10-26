# shellcheck shell=bash
# Cleanup, unmounting and the final message.

finalize_depclean() {
    chroot_run "$(T 'Removing unnecessary dependencies (depclean)')" \
        emerge --ask=n --quiet --depclean || return 1
    chroot_run "$(T 'Updating the environment')" env-update || true
    log_info "depclean finished"
}

finalize_remove_artifacts() {
    local leftover
    stage3_cleanup
    while IFS= read -r leftover; do
        [[ -n $leftover ]] || continue
        rm -f -- "$leftover"
    done < <(find "$GI_ROOT" -maxdepth 1 -type f -name 'stage3-*.tar.*' -print 2>/dev/null || true)
    sync
}

finalize_unmount() {
    chroot_unmount
    if ! disks_unmount_all; then
        ui_error "$(T 'Failed to unmount')" \
            "$(T 'Check whether files in %s are still in use (for example, an open shell in the chroot).' "$GI_ROOT")"
        return 1
    fi
    log_info "all target filesystems unmounted"
}

finalize_message() {
    local login=$CFG_USERNAME desktop
    desktop=$(T 'not selected')
    [[ $CFG_CREATE_USER == yes ]] || login=root
    if desktop_is_enabled; then
        desktop="$(desktop_label) ($(desktop_display_manager))"
    fi
    ui_header "$(T 'Installation complete')" "$(T 'Gentoo Linux is installed on %s' "$CFG_DISK")"
    ui_wrap "$(T 'The system is configured and ready for its first boot.\n\n  Hostname:        %s\n  User:            %s\n  Bootloader:      GRUB (%s)\n  Kernel:          %s\n  Desktop:         %s\n  Timezone:        %s\n  Locale:          %s\n  Network:         %s\n\nInstallation logs: %s\nConfiguration:     %s\n\nRemove the installation media and reboot.\nChange the passwords after the first login if necessary.' \
        "$CFG_HOSTNAME" "$login" "${CFG_BOOT_MODE^^}" "$CFG_KERNEL_MODE" "$desktop" "$CFG_TIMEZONE" "$CFG_LOCALE" "$CFG_NETWORK" "$GI_LOG_DIR" "$GI_CONFIG_FILE")"
    ui_footer "$(T 'Enter - close')"
    ui_read_key || true
}

step_finalize() {
    require_mountpoint "$GI_ROOT"
    chroot_mount || return 1
    finalize_depclean || return 1
    finalize_remove_artifacts
    finalize_unmount || return 1
    finalize_message
    log_info "finalize step finished"
}
