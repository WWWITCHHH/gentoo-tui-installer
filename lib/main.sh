# shellcheck shell=bash
# Entry point logic: CLI, resumes, step orchestration.

GI_CONFIG_EXPLICIT=0

main_usage() {
    cat <<EOF
${GI_NAME} ${GI_VERSION}

Использование: gentoo-installer [параметры]

Параметры:
  -c, --config FILE   использовать указанный файл конфигурации
  -r, --resume        сразу продолжить установку с сохранённого состояния
  -y, --yes           не показывать предупреждение и не требовать ERASE
                      (пароли и интерактивные вопросы остаются)
      --debug         писать отладочные сообщения в stderr
  -h, --help          показать эту справку
  -V, --version       показать версию

Установщик должен запускаться от root из Gentoo Minimal Installation CD.
Журналы: ${GI_LOG_DIR}
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
                (($# >= 2)) || die "параметр $1 требует путь к файлу"
                GI_CONFIG_FILE=$2
                GI_CONFIG_EXPLICIT=1
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
                die "неизвестный параметр: $1 (см. --help)"
                ;;
        esac
        shift
    done

    if ((GI_CONFIG_EXPLICIT)); then
        if [[ $GI_CONFIG_FILE != /* ]]; then
            GI_CONFIG_FILE="$(readlink -m -- "$GI_CONFIG_FILE")"
        fi
        [[ -f $GI_CONFIG_FILE ]] || die "файл конфигурации не найден: $GI_CONFIG_FILE"
    fi
    if ((GI_RESUME)) && [[ ! -f $GI_CONFIG_FILE ]]; then
        die "для --resume нужен сохранённый файл конфигурации: $GI_CONFIG_FILE"
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
        disk) printf 'Создание разделов, файловых систем и монтирование целевой системы.' ;;
        stage3) printf 'Загрузка, проверка подписи и распаковка stage3, затем установка Portage.' ;;
        portage) printf 'Копирование resolv.conf, chroot, make.conf, синхронизация и профиль Portage.' ;;
        kernel) printf 'Прошивки, микрокод и ядро: gentoo-kernel-bin, gentoo-kernel или gentoo-sources.' ;;
        system) printf 'Имя хоста, время, локаль, раскладка, fstab, пароль root и пользователь.' ;;
        tools) printf 'Сеть, SSH, cron, chrony, системный журнал, sudo и gentoolkit.' ;;
        bootloader) printf 'Установка GRUB в ESP или MBR и генерация grub.cfg.' ;;
        desktop) printf 'Xorg, XFCE + LightDM или GNOME + GDM; пропускается при DESKTOP=none.' ;;
        finalize) printf 'depclean, удаление временных файлов и размонтирование.' ;;
        *) printf '%s' "$1" ;;
    esac
}

main_banner() {
    ui_header "" ""
    ui_wrap "${GI_NAME} ${GI_VERSION}
Git: ${GI_GIT_VERSION:-недоступен}

Установщик проведёт вас через этапы Gentoo Handbook:
разметка → stage3 → Portage → ядро → система → службы → GRUB
→ графическое окружение → завершение.

Файл конфигурации: ${GI_CONFIG_FILE}
Рабочий каталог:   ${GI_WORKDIR}
Журнал:            ${GI_LOG_FILE}"
    if state_has_progress; then
        printf '\n'
        ui_wrap "Найдено сохранённое состояние. Завершённые этапы будут пропущены."
    fi
    ui_footer "Enter — открыть меню"
    ui_read_key || true
}

main_resume_prompt() {
    if state_is_done finalize; then
        ui_msg "Установка уже завершена" \
            "Состояние последней установки сохранено. Чтобы начать заново, выберите
«Сбросить состояние» в главном меню."
        return 0
    fi
    if ! state_has_progress; then
        return 0
    fi
    if ui_confirm "Незавершённая установка" \
        "Найдены завершённые этапы. Продолжить установку с места остановки?" yes; then
        log_info "resuming existing installation"
        return 0
    fi
    chroot_unmount
    state_reset
    disks_unmount_all || warn "не удалось размонтировать разделы"
    ui_msg "Начинаем заново" "Состояние сброшено. Параметры конфигурации сохранены."
    log_info "state reset by user"
}

main_show_validation_errors() {
    local error text=""
    for error in "${VALIDATION_ERRORS[@]}"; do
        text+="• ${error}"$'\n'
    done
    ui_error "Проверьте параметры установки" "$text"
}

main_start_installation() {
    if state_is_done finalize; then
        ui_msg "Установка уже завершена" "Сбросьте состояние, чтобы установить систему заново."
        return 1
    fi

    if ! state_has_progress && ((!GI_ASSUME_YES)); then
        preflight_install_media_warning || return 1
    fi
    if ! preflight_run; then
        if ((PREFLIGHT_FAILED)); then
            ui_error "Проверка окружения не пройдена" \
                "Исправьте проблемы, отмеченные красным, и повторите запуск."
        fi
        return 1
    fi

    if [[ $CFG_DISK_MODE == auto ]]; then
        if [[ -z $CFG_DISK || ! -b $CFG_DISK ]]; then
            disks_select_disk || return 1
        fi
    elif [[ -z $CFG_PART_ROOT || ! -b $CFG_PART_ROOT ]]; then
        ui_msg "Ручная разметка" "Назначьте разделы для root, ESP//boot, swap и /home."
        disks_manual_assign || return 1
    fi

    config_derived
    if ! config_validate; then
        main_show_validation_errors
        return 1
    fi
    config_save
    log_info "installation started"
    installation_run
}

installation_run() {
    local step func index
    if state_is_done disk; then
        ui_msg "Восстановление монтирования" "Целевая система уже размечена. Проверяю и монтирую разделы."
        if ! disks_mount_all; then
            ui_error "Не удалось смонтировать" "Проверьте подключение диска и параметры разделов."
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
            ui_error "Этап не завершён" \
                "Этап «$(state_label "$step")» не завершён. Исправьте проблему и выберите
«Начать / продолжить установку» — завершённые этапы будут пропущены."
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
    printf '\nУстановщик прерван. Состояние сохранено; запустите снова для продолжения.\n'
    printf 'Журнал: %s\n' "$GI_LOG_FILE"
    exit 130
}

main() {
    main_parse_args "$@"
    if [[ ! -t 0 || ! -t 1 ]]; then
        die "установщику нужен интерактивный терминал (stdin и stdout)"
    fi
    require_root
    init_workdir
    config_defaults

    if [[ -f $GI_CONFIG_FILE ]]; then
        config_load "$GI_CONFIG_FILE"
    elif ((GI_CONFIG_EXPLICIT)); then
        die "файл конфигурации не найден: $GI_CONFIG_FILE"
    fi
    config_derived
    state_load

    log_info "config file: $GI_CONFIG_FILE"
    log_info "state file: $GI_STATE_FILE"
    if ((GI_ASSUME_YES)); then
        log_warn "assume-yes mode enabled"
    fi

    trap main_on_signal INT TERM HUP
    ui_init
    main_banner

    if ((GI_RESUME)); then
        if state_is_done finalize; then
            ui_cleanup
            printf '\nУстановка уже завершена. Для повторной установки сбросьте состояние.\n'
            printf 'Журнал: %s\n' "$GI_LOG_FILE"
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
    printf '\nЖурнал установки: %s\n' "$GI_LOG_FILE"
    if state_is_done finalize; then
        printf 'Установка завершена. Перезагрузите систему, извлеките установочный носитель.\n'
    else
        printf 'Для продолжения запустите: %s --resume\n' "$GI_SCRIPT_DIR/gentoo-installer"
    fi
    return 0
}
