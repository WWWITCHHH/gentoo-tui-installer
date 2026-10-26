# shellcheck shell=bash
# System services and optional administration tools.

tools_enable_service() {
    local service=$1
    if [[ $CFG_INIT == systemd ]]; then
        chroot_run "$(T 'Enabling service %s' "$service")" systemctl enable "$service" || return 1
    else
        chroot_run "$(T 'Enabling service %s' "$service")" rc-update add "$service" default || return 1
    fi
}

tools_write_sudoers() {
    local dir="$GI_ROOT/etc/sudoers.d"
    [[ $CFG_SUDO == yes ]] || return 0
    ensure_dir "$dir"
    chmod 0750 -- "$dir"
    write_file_atomic "$dir/10-wheel" 0440 <<'EOF'
# Members of the wheel group may use sudo with their own password.
%wheel ALL=(ALL:ALL) ALL
EOF
    chroot_run "$(T 'Checking sudoers')" visudo -cf /etc/sudoers || return 1
    log_info "sudoers wheel rule installed"
}

tools_network_packages() {
    case "$CFG_NETWORK" in
        dhcpcd) printf 'net-misc/dhcpcd\n' ;;
        networkmanager) printf 'net-misc/networkmanager\n' ;;
        none) ;;
    esac
}

tools_network_service() {
    case "$CFG_NETWORK" in
        dhcpcd) printf 'dhcpcd\n' ;;
        networkmanager) printf 'NetworkManager\n' ;;
        none) ;;
    esac
}

step_tools() {
    require_mountpoint "$GI_ROOT"
    chroot_mount || return 1
    local -a packages=(app-portage/gentoolkit)
    local package service

    package=$(tools_network_packages)
    [[ -n $package ]] && packages+=("$package")
    if [[ $CFG_SSH == yes ]]; then
        packages+=(net-misc/openssh)
    fi
    if [[ $CFG_CRON == yes ]]; then
        packages+=(sys-process/cronie)
    fi
    if [[ $CFG_CHRONY == yes ]]; then
        packages+=(net-misc/chrony)
    fi
    if [[ $CFG_SYSLOG == yes ]]; then
        if [[ $CFG_INIT == systemd ]]; then
            packages+=(app-admin/rsyslog)
        else
            packages+=(app-admin/sysklogd)
        fi
    fi
    if [[ $CFG_SUDO == yes ]]; then
        packages+=(app-admin/sudo)
    fi

    chroot_run "$(T 'Installing system services and utilities')" \
        emerge --ask=n --quiet "${packages[@]}" || return 1

    service=$(tools_network_service)
    if [[ -n $service ]]; then
        tools_enable_service "$service" || return 1
    fi
    if [[ $CFG_SSH == yes ]]; then
        tools_enable_service sshd || return 1
    fi
    if [[ $CFG_CRON == yes ]]; then
        tools_enable_service cronie || return 1
    fi
    if [[ $CFG_CHRONY == yes ]]; then
        tools_enable_service chronyd || return 1
    fi
    if [[ $CFG_SYSLOG == yes ]]; then
        if [[ $CFG_INIT == systemd ]]; then
            tools_enable_service rsyslog || return 1
        else
            tools_enable_service sysklogd || return 1
        fi
    fi
    tools_write_sudoers || return 1
    config_save
    log_info "tools step finished"
}
