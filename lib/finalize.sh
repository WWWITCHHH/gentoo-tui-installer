# shellcheck shell=bash
# Cleanup, unmounting and the final message.

finalize_depclean() {
    chroot_run "Удаление ненужных зависимостей (depclean)" \
        emerge --ask=n --quiet --depclean || return 1
    chroot_run "Обновление окружения" env-update || true
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
        ui_error "Не удалось размонтировать" \
            "Проверьте, не используются ли файлы в ${GI_ROOT} (например, открыт shell в chroot)."
        return 1
    fi
    log_info "all target filesystems unmounted"
}

finalize_message() {
    local login=$CFG_USERNAME
    [[ $CFG_CREATE_USER == yes ]] || login=root
    ui_header "Установка завершена" "Gentoo Linux установлен на ${CFG_DISK}"
    ui_wrap "Система настроена и готова к первой загрузке.

  Имя хоста:       ${CFG_HOSTNAME}
  Пользователь:    ${login}
  Загрузчик:       GRUB (${CFG_BOOT_MODE^^})
  Ядро:            ${CFG_KERNEL_MODE}
  Часовой пояс:    ${CFG_TIMEZONE}
  Локаль:          ${CFG_LOCALE}
  Сеть:            ${CFG_NETWORK}

Журналы установки: ${GI_LOG_DIR}
Конфигурация:      ${GI_CONFIG_FILE}

Извлеките установочный носитель и перезагрузитесь командой reboot.
При первом входе смените пароли, если это необходимо."
    ui_footer "Enter — закрыть"
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
