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
    ui_msg "Этап уже завершён" \
        "${title}: этот этап уже выполнен, поэтому изменения не будут применены.
Чтобы настроить установку заново, сбросьте состояние в главном меню."
    return 1
}

wizard_choose_fs() {
    local title=$1 current=$2
    disks_choose_fs "$title" "$current"
}

wizard_edit_boot() {
    local choice
    ui_menu "Режим загрузки" "Текущий режим Minimal CD: $([[ -d /sys/firmware/efi ]] && printf UEFI || printf BIOS)" \
        "$CFG_BOOT_MODE" \
        "uefi|UEFI + GPT|ESP в /efi, загрузчик GRUB (x86_64-efi)" \
        "bios|BIOS + MBR|раздел /boot, загрузчик GRUB (i386-pc)" || return 0
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
        ui_menu "Раздел swap" "Swap можно не создавать, если достаточно RAM" "$CFG_SWAP_MODE" \
            "auto|Автоматически|По таблице Gentoo Handbook: 4–8 GiB в зависимости от RAM" \
            "none|Без swap|Не создавать раздел подкачки" \
            "custom|Свой размер|Указать размер в MiB" || return 0
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
                if ui_int_input "Размер swap" "Укажите размер swap в MiB:" "$default" 1 "$max"; then
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
        ui_menu "Раздел /home" "Отдельный /home упрощает переустановку системы" "$CFG_HOME_MODE" \
            "no|Без отдельного /home|Домашние каталоги на корневом разделе" \
            "separate|Отдельный /home|Создать или использовать отдельный раздел" || return 0
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
        if ui_int_input "Размер /home" "Укажите размер /home в MiB:" "$default" 1024 "$max"; then
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
        ui_msg "Разделы назначены" "Форматирование и проверка файловых систем будут выполнены на этапе разметки."
    fi
}

wizard_edit_disk() {
    local choice
    if state_is_done disk; then
        ui_msg "Диск уже размечен" \
            "Разметка завершена. Чтобы изменить диск или схему разделов,
сбросьте состояние установки в главном меню."
        return 0
    fi
    while :; do
        local plan_note="Нажмите «Начать установку» после проверки параметров"
        if [[ $CFG_DISK_MODE == auto && -n $CFG_DISK && -b $CFG_DISK ]]; then
            local disk_mib
            disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
            if disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" 2>/dev/null; then
                plan_note="План: $(disk_plan_summary)"
            else
                plan_note="План: ошибка — ${PLAN_ERROR}"
            fi
        fi
        ui_menu "Диск и разметка" "$plan_note" "" \
            "mode|Режим: ${CFG_DISK_MODE}|auto — автоматическая схема, manual — свои разделы" \
            "disk|Целевой диск: ${CFG_DISK:-не выбран}|Выбрать диск для установки" \
            "boot|Режим загрузки: ${CFG_BOOT_MODE}|UEFI+GPT или BIOS+MBR" \
            "rootfs|Файловая система root: ${CFG_ROOT_FS}|xfs, ext4 или btrfs" \
            "homefs|Файловая система /home: ${CFG_HOME_FS}|Используется для отдельного /home" \
            "swap|Swap: ${CFG_SWAP_MODE}|Автоматически, без swap или свой размер" \
            "home|/home: ${CFG_HOME_MODE}|Отдельный раздел или в составе root" \
            "manual|Назначить разделы вручную|Для режима manual: выбрать существующие разделы" \
            "back|Назад|Вернуться в главное меню" || return 0
        choice=$UI_RESULT
        case "$choice" in
            mode)
                if ui_menu "Режим разметки" "Автоматическая схема уничтожит таблицу разделов" "$CFG_DISK_MODE" \
                    "auto|Автоматически|Создать GPT/MBR и разделы по плану" \
                    "manual|Вручную|Использовать уже созданные разделы"; then
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
            rootfs) wizard_choose_fs "Файловая система root" "$CFG_ROOT_FS" && { CFG_ROOT_FS=$UI_RESULT; wizard_save; } ;;
            homefs) wizard_choose_fs "Файловая система /home" "$CFG_HOME_FS" && { CFG_HOME_FS=$UI_RESULT; wizard_save; } ;;
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
    wizard_step_locked portage "Stage3 и Portage" || return 0
    while :; do
        ui_menu "Stage3 и Portage" "Параметры загрузки stage3 и сборки пакетов" "" \
            "flavor|Stage3: ${CFG_STAGE_FLAVOR}|openrc/systemd, desktop-варианты" \
            "mirror|Зеркало: ${CFG_MIRROR}|Базовый URL distfiles.gentoo.org" \
            "stageurl|Прямой URL stage3: ${CFG_STAGE_URL:-автоматически}|Пусто — взять latest-stage3" \
            "profile|Профиль: ${CFG_PROFILE}|stage, desktop, gnome, kde, hardened; согласуется с DESKTOP" \
            "cpu|CPU_FLAGS_X86: ${CFG_CPU_FLAGS}|Определить через cpuid2cpuflags" \
            "world|Обновлять @world: ${CFG_UPDATE_WORLD}|Может занять много времени" \
            "jobs|MAKEOPTS: ${CFG_MAKE_JOBS}|Число параллельных задач сборки" \
            "cflags|CFLAGS: ${CFG_CFLAGS}|Флаги компилятора" \
            "video|VIDEO_CARDS: ${CFG_VIDEO_CARDS:-не заданы}|Драйверы GPU для Portage" \
            "use|USE дополнительно: ${CFG_USE_EXTRA:-нет}|Дополнительные USE-флаги" \
            "back|Назад|Вернуться" || return 0
        choice=$UI_RESULT
        case "$choice" in
            flavor)
                if state_is_done stage3; then
                    ui_msg "Stage3 уже установлен" \
                        "Вариант stage3 нельзя изменить после распаковки.
Сбросьте состояние, если нужен другой вариант."
                elif ui_menu "Вариант stage3" "Выберите инициализацию и набор ПО" "$CFG_STAGE_FLAVOR" \
                    "openrc|OpenRC|Классический Gentoo, минимальный stage3" \
                    "systemd|systemd|Stage3 с systemd" \
                    "desktop-openrc|Desktop OpenRC|Stage3 с графическими библиотеками" \
                    "desktop-systemd|Desktop systemd|Stage3 с графикой и systemd"; then
                    CFG_STAGE_FLAVOR=$UI_RESULT
                    config_derived
                    wizard_save
                fi
                ;;
            mirror)
                ui_input "Зеркало distfiles" "Базовый URL зеркала:" "$CFG_MIRROR" validate_url \
                    "Например: https://distfiles.gentoo.org" no &&
                    { CFG_MIRROR=${UI_RESULT%/}; wizard_save; }
                ;;
            stageurl)
                ui_input "Прямой URL stage3" "Оставьте пустым для автоматического выбора:" \
                    "$CFG_STAGE_URL" validate_optional_url "Полный URL до .tar.xz" no &&
                    { CFG_STAGE_URL=$UI_RESULT; wizard_save; }
                ;;
            profile)
                if ui_menu "Профиль Portage" "Профиль определяет USE-флаги и набор пакетов" "$CFG_PROFILE" \
                    "stage|Stage|Базовый профиль без графики" \
                    "desktop|Desktop|Графический профиль" \
                    "gnome|GNOME|Desktop + GNOME" \
                    "kde|KDE Plasma|Desktop + KDE" \
                    "hardened|Hardened|Усиленная защита"; then
                    CFG_PROFILE=$UI_RESULT
                    wizard_save
                fi
                ;;
            cpu)
                CFG_CPU_FLAGS=$(wizard_bool "CPU_FLAGS_X86" "Определить CPU-флаги через cpuid2cpuflags?" "$CFG_CPU_FLAGS")
                wizard_save
                ;;
            world)
                CFG_UPDATE_WORLD=$(wizard_bool "Обновление @world" \
                    "Выполнить emerge --update --deep --newuse @world? Это может быть долго." "$CFG_UPDATE_WORLD" no)
                wizard_save
                ;;
            jobs)
                if ui_menu "MAKEOPTS" "Число параллельных задач сборки" "$CFG_MAKE_JOBS" \
                    "auto|Автоматически|С учётом CPU и RAM: $(make_jobs_suggestion)" \
                    "custom|Указать число|Ввести вручную"; then
                    if [[ $UI_RESULT == custom ]]; then
                        value=$(make_jobs_suggestion)
                        ui_int_input "MAKEOPTS" "Число задач make:" "$value" 1 256 &&
                            { CFG_MAKE_JOBS=$UI_RESULT; wizard_save; }
                    else
                        CFG_MAKE_JOBS=auto
                        wizard_save
                    fi
                fi
                ;;
            cflags)
                ui_input "CFLAGS" "Флаги компилятора:" "$CFG_CFLAGS" validate_cflags \
                    "Обычно: -march=native -O2 -pipe" no &&
                    { CFG_CFLAGS=$UI_RESULT; wizard_save; }
                ;;
            video)
                ui_input "VIDEO_CARDS" "Драйверы видео (через пробел, можно пусто):" \
                    "$CFG_VIDEO_CARDS" validate_optional_tokens \
                    "Например: amdgpu radeonsi или intel" no &&
                    { CFG_VIDEO_CARDS=$UI_RESULT; wizard_save; }
                ;;
            use)
                ui_input "USE-флаги" "Дополнительные USE-флаги (через пробел):" "$CFG_USE_EXTRA" \
                    validate_use_flags "Например: cups bluetooth" no &&
                    { CFG_USE_EXTRA=$UI_RESULT; wizard_save; }
                ;;
            back) return 0 ;;
        esac
    done
}

wizard_edit_kernel() {
    local choice
    wizard_step_locked kernel "Ядро и загрузчик" || return 0
    while :; do
        ui_menu "Ядро и загрузчик" "Параметры установки ядра" "" \
            "mode|Метод: ${CFG_KERNEL_MODE}|bin, dist или manual" \
            "firmware|Прошивки linux-firmware: ${CFG_FIRMWARE}|Нужны для Wi-Fi, GPU и др." \
            "microcode|Микрокод CPU: ${CFG_MICROCODE}|auto, none, intel или amd" \
            "cmdline|Kernel cmdline: ${CFG_KERNEL_CMDLINE:-пусто}|Дополнительные параметры ядра" \
            "boot|Загрузчик: ${CFG_BOOTLOADER}|В этой версии только GRUB" \
            "back|Назад|Вернуться" || return 0
        choice=$UI_RESULT
        case "$choice" in
            mode)
                if ui_menu "Метод установки ядра" "Выберите способ получения ядра" "$CFG_KERNEL_MODE" \
                    "bin|gentoo-kernel-bin|Готовое бинарное ядро, быстро" \
                    "dist|gentoo-kernel|Сборка ядра с конфигурацией Gentoo" \
                    "manual|gentoo-sources|Ручная конфигурация через menuconfig"; then
                    CFG_KERNEL_MODE=$UI_RESULT
                    wizard_save
                fi
                ;;
            firmware)
                CFG_FIRMWARE=$(wizard_bool "Прошивки устройств" \
                    "Установить sys-kernel/linux-firmware? Пакет большой." "$CFG_FIRMWARE")
                wizard_save
                ;;
            microcode)
                if ui_menu "Микрокод CPU" "Обновления микрокода загружаются при старте" "$CFG_MICROCODE" \
                    "auto|Автоматически|Определить производителя CPU" \
                    "none|Не устанавливать|" \
                    "intel|Intel|sys-firmware/intel-microcode" \
                    "amd|AMD|sys-firmware/amd-ucode"; then
                    CFG_MICROCODE=$UI_RESULT
                    wizard_save
                fi
                ;;
            cmdline)
                ui_input "Kernel cmdline" "Дополнительные параметры (root добавляется автоматически):" \
                    "$CFG_KERNEL_CMDLINE" validate_kernel_cmdline "Например: quiet splash" no &&
                    { CFG_KERNEL_CMDLINE=$UI_RESULT; wizard_save; }
                ;;
            boot) ui_msg "Загрузчик" "В этой версии поддерживается только GRUB для UEFI и BIOS." ;;
            back) return 0 ;;
        esac
    done
}

wizard_edit_desktop() {
    local choice old_profile
    if state_is_done desktop; then
        ui_msg "Этап уже завершён" \
            "Графическое окружение уже установлено. Чтобы изменить выбор,
сбросьте состояние установки в главном меню."
        return 0
    fi
    old_profile=$CFG_PROFILE
    if ! ui_menu "Графическое окружение" \
        "XFCE или GNOME; профиль Portage подстраивается под выбор" "$CFG_DESKTOP" \
        "none|Без графической среды|Установить только консольную систему" \
        "xfce|XFCE + LightDM|Лёгкая графическая среда для повседневной работы" \
        "gnome|GNOME + GDM|Полноценная среда GNOME; большой объём пакетов"; then
        return 0
    fi
    choice=$UI_RESULT
    CFG_DESKTOP=$choice
    config_derived
    wizard_save
    if [[ $CFG_PROFILE != "$old_profile" ]] && state_is_done portage; then
        ui_msg "Профиль изменён после Portage" \
            "Portage уже завершён, поэтому новый профиль ${CFG_PROFILE} не будет
применён к установленной системе. Графическая среда будет установлена с
текущим профилем. Для смены профиля сбросьте состояние и начните заново."
    fi
    if [[ $choice != none && -z $CFG_VIDEO_CARDS ]]; then
        ui_msg "VIDEO_CARDS не заданы" \
            "Для аппаратного ускорения укажите драйверы GPU в разделе
«Stage3 и Portage → VIDEO_CARDS». Без VIDEO_CARDS Xorg может работать
только с базовым режимом."
    fi
}

wizard_edit_system() {
    local choice
    wizard_step_locked system "Система" || return 0
    while :; do
        ui_menu "Система" "Имя, время, локаль и консоль" "" \
            "hostname|Имя хоста: ${CFG_HOSTNAME}|" \
            "timezone|Часовой пояс: ${CFG_TIMEZONE}|" \
            "locale|Локаль: ${CFG_LOCALE}|" \
            "keymap|Раскладка консоли: ${CFG_KEYMAP}|" \
            "hwclock|Часы: ${CFG_HWCLOCK}|UTC или local" \
            "back|Назад|Вернуться" || return 0
        choice=$UI_RESULT
        case "$choice" in
            hostname)
                ui_input "Имя хоста" "Введите имя хоста:" "$CFG_HOSTNAME" validate_hostname \
                    "Латинские буквы, цифры, точки и дефис" no &&
                    { CFG_HOSTNAME=$UI_RESULT; wizard_save; }
                ;;
            timezone)
                ui_input "Часовой пояс" "Введите зону IANA:" "$CFG_TIMEZONE" validate_timezone \
                    "Например: Europe/Moscow или UTC" no &&
                    { CFG_TIMEZONE=$UI_RESULT; wizard_save; }
                ;;
            locale)
                ui_input "Локаль" "Введите UTF-8 локаль:" "$CFG_LOCALE" validate_locale \
                    "Например: ru_RU.UTF-8 или en_US.UTF-8" no &&
                    { CFG_LOCALE=$UI_RESULT; wizard_save; }
                ;;
            keymap)
                ui_input "Раскладка консоли" "Введите keymap:" "$CFG_KEYMAP" validate_keymap \
                    "Например: us или ru" no &&
                    { CFG_KEYMAP=$UI_RESULT; wizard_save; }
                ;;
            hwclock)
                if ui_menu "Аппаратные часы" "Как хранить время в RTC" "$CFG_HWCLOCK" \
                    "UTC|UTC|Рекомендуется, особенно для dual boot" \
                    "local|Local|Локальное время"; then
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
    wizard_step_locked tools "Службы и пользователи" || return 0
    while :; do
        ui_menu "Службы и пользователи" "Сеть, SSH, журналирование и учётные записи" "" \
            "network|Сеть: ${CFG_NETWORK}|dhcpcd, NetworkManager или без настройки" \
            "ssh|SSH-сервер: ${CFG_SSH}|net-misc/openssh" \
            "cron|Cron: ${CFG_CRON}|sys-process/cronie" \
            "chrony|Синхронизация времени: ${CFG_CHRONY}|net-misc/chrony" \
            "syslog|Системный журнал: ${CFG_SYSLOG}|sysklogd или rsyslog" \
            "sudo|Установить sudo: ${CFG_SUDO}|Правило для группы wheel" \
            "createuser|Создать пользователя: ${CFG_CREATE_USER}|Пароль запрашивается на этапе системы" \
            "username|Имя пользователя: ${CFG_USERNAME}|" \
            "back|Назад|Вернуться" || return 0
        choice=$UI_RESULT
        case "$choice" in
            network)
                if ui_menu "Настройка сети" "Автоматическая настройка через DHCP" "$CFG_NETWORK" \
                    "dhcpcd|dhcpcd|Простой DHCP-клиент" \
                    "networkmanager|NetworkManager|Удобно для Wi-Fi и графической среды" \
                    "none|Без настройки|Настроить сеть вручную после установки"; then
                    CFG_NETWORK=$UI_RESULT
                    wizard_save
                fi
                ;;
            ssh) CFG_SSH=$(wizard_bool "SSH-сервер" "Установить и включить OpenSSH?" "$CFG_SSH" no); wizard_save ;;
            cron) CFG_CRON=$(wizard_bool "Cron" "Установить и включить cronie?" "$CFG_CRON"); wizard_save ;;
            chrony) CFG_CHRONY=$(wizard_bool "Chrony" "Установить и включить синхронизацию времени?" "$CFG_CHRONY"); wizard_save ;;
            syslog) CFG_SYSLOG=$(wizard_bool "Системный журнал" "Установить sysklogd/rsyslog?" "$CFG_SYSLOG"); wizard_save ;;
            sudo) CFG_SUDO=$(wizard_bool "sudo" "Установить sudo и разрешить группе wheel?" "$CFG_SUDO"); wizard_save ;;
            createuser)
                CFG_CREATE_USER=$(wizard_bool "Пользователь" "Создать обычного пользователя?" "$CFG_CREATE_USER")
                wizard_save
                ;;
            username)
                ui_input "Имя пользователя" "Введите имя пользователя:" "$CFG_USERNAME" validate_username \
                    "Строчные латинские буквы, цифры, _ и -" no &&
                    { CFG_USERNAME=$UI_RESULT; wizard_save; }
                ;;
            back) return 0 ;;
        esac
    done
}

wizard_summary_text() {
    local disk_mib="" plan=""
    if [[ $CFG_DISK_MODE == auto && -n $CFG_DISK && -b $CFG_DISK ]]; then
        disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
        if disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" 2>/dev/null; then
            plan=$(disk_plan_print)
        else
            plan="Ошибка плана: ${PLAN_ERROR}"
        fi
    fi
    printf 'Режим загрузки: %s\n' "$CFG_BOOT_MODE"
    printf 'Режим разметки: %s\n' "$CFG_DISK_MODE"
    printf 'Диск: %s\n' "${CFG_DISK:-не выбран}"
    printf 'Root FS: %s; /home FS: %s\n' "$CFG_ROOT_FS" "$CFG_HOME_FS"
    printf 'Swap: %s; /home: %s\n\n' "$CFG_SWAP_MODE" "$CFG_HOME_MODE"
    if [[ -n $plan ]]; then
        printf '%s\n' "$plan"
    fi
    printf 'Stage3: %s\n' "$CFG_STAGE_FLAVOR"
    printf 'Зеркало: %s\n' "$CFG_MIRROR"
    [[ -n $CFG_STAGE_URL ]] && printf 'Прямой URL: %s\n' "$CFG_STAGE_URL"
    printf 'Профиль: %s (%s)\n' "$CFG_PROFILE" "$CFG_INIT"
    printf 'Графическая среда: %s\n' "$(desktop_label)"
    printf 'CPU_FLAGS: %s; MAKEOPTS: %s; @world: %s\n' "$CFG_CPU_FLAGS" "$CFG_MAKE_JOBS" "$CFG_UPDATE_WORLD"
    printf 'CFLAGS: %s\n' "$CFG_CFLAGS"
    [[ -n $CFG_VIDEO_CARDS ]] && printf 'VIDEO_CARDS: %s\n' "$CFG_VIDEO_CARDS"
    [[ -n $CFG_USE_EXTRA ]] && printf 'USE: %s\n' "$CFG_USE_EXTRA"
    printf '\nЯдро: %s; прошивки: %s; микрокод: %s\n' "$CFG_KERNEL_MODE" "$CFG_FIRMWARE" "$CFG_MICROCODE"
    printf 'Kernel cmdline: %s\n' "${CFG_KERNEL_CMDLINE:-—}"
    printf 'Загрузчик: %s\n' "$CFG_BOOTLOADER"
    printf '\nХост: %s; TZ: %s; locale: %s; keymap: %s; hwclock: %s\n' \
        "$CFG_HOSTNAME" "$CFG_TIMEZONE" "$CFG_LOCALE" "$CFG_KEYMAP" "$CFG_HWCLOCK"
    printf 'Сеть: %s; SSH: %s; cron: %s; chrony: %s; syslog: %s; sudo: %s\n' \
        "$CFG_NETWORK" "$CFG_SSH" "$CFG_CRON" "$CFG_CHRONY" "$CFG_SYSLOG" "$CFG_SUDO"
    printf 'Пользователь: %s (создавать: %s)\n' "$CFG_USERNAME" "$CFG_CREATE_USER"
}

wizard_show_summary() {
    local tmp
    if ! config_validate; then
        local errors=""
        local error
        for error in "${VALIDATION_ERRORS[@]}"; do
            errors+="• ${error}"$'\n'
        done
        ui_error "Проверьте параметры" "$errors"
        return 1
    fi
    tmp=$(mktemp "${GI_WORKDIR}/summary.XXXXXX")
    wizard_summary_text >"$tmp"
    chmod 0600 -- "$tmp"
    ui_show_file "Сводка конфигурации" "$tmp"
    rm -f -- "$tmp"
    return 0
}

wizard_load_config() {
    local path
    ui_input "Загрузка конфигурации" "Путь к файлу конфигурации:" "$GI_CONFIG_FILE" \
        validate_nonempty "Файл формата KEY=\"value\"" no || return 0
    path=$UI_RESULT
    if [[ ! -f $path ]]; then
        ui_error "Файл не найден" "$path"
        return 0
    fi
    config_load "$path"
    config_derived
    config_save
    ui_msg "Конфигурация загружена" "Параметры прочитаны из ${path} и сохранены в ${GI_CONFIG_FILE}."
}

wizard_about() {
    ui_header "О программе" "${GI_NAME} ${GI_VERSION}"
    ui_wrap "Установщик Gentoo Linux с консольным интерфейсом.

Поддерживаются UEFI+GPT и BIOS+MBR, OpenRC и systemd,
бинарное, дистрибутивное и ручное ядро, GRUB,
опциональные XFCE + LightDM и GNOME + GDM.
Не поддерживаются LUKS, LVM, RAID, Secure Boot и dual boot.

Проект распространяется по лицензии MIT.
Журналы: ${GI_LOG_DIR}
Состояние: ${GI_STATE_FILE}"
    ui_pause "Enter — вернуться"
}

wizard_reset_state() {
    if ! ui_confirm "Сбросить состояние" \
        "Удалить отметки о завершённых этапах? Конфигурация и данные на диске не удаляются." no; then
        return 0
    fi
    chroot_unmount
    disks_unmount_all || warn "не удалось размонтировать целевые разделы"
    state_reset
    ui_msg "Состояние сброшено" "Следующая установка начнётся с этапа разметки."
}

wizard_main() {
    local choice
    local -a items=()
    while :; do
        local resume_note="Новая установка"
        state_has_progress && resume_note="Есть завершённые этапы; установка продолжится с места остановки"
        items=(
            "install|Начать / продолжить установку|${resume_note}"
            "disk|Диск и разметка|Режим, диск, файловые системы, swap и /home"
            "stage|Stage3 и Portage|Зеркало, профиль, CFLAGS, USE, MAKEOPTS"
            "kernel|Ядро и загрузчик|Бинарное, dist или ручное ядро"
            "system|Система|Имя, время, локаль, раскладка, часы"
            "services|Службы и пользователи|Сеть, SSH, cron, chrony, syslog, sudo"
            "desktop|Графическое окружение|XFCE, GNOME или без графической среды"
            "summary|Проверить конфигурацию|Показать сводку и ошибки"
            "load|Загрузить конфигурацию|Прочитать файл KEY=\"value\""
            "save|Сохранить конфигурацию|Записать параметры в ${GI_CONFIG_FILE}"
            "shell|Открыть оболочку|Выйти из установщика без размонтирования"
            "about|О программе|Версия, ограничения, журналы"
        )
        state_has_progress && items+=("reset|Сбросить состояние|Начать установку заново")
        items+=("exit|Выход|Завершить работу установщика")
        ui_menu "Главное меню" "Сначала проверьте параметры, затем начните установку" "" \
            "${items[@]}" || return 0
        choice=$UI_RESULT
        case "$choice" in
            install)
                if state_is_done finalize; then
                    ui_msg "Установка уже завершена" \
                        "Сбросьте состояние, если хотите выполнить установку заново."
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
            summary) wizard_show_summary || true ;;
            load) wizard_load_config ;;
            save) wizard_save; ui_msg "Сохранено" "Конфигурация записана в ${GI_CONFIG_FILE}." ;;
            shell) ui_interactive "Оболочка (exit — вернуться в установщик)" /bin/bash -l ;;
            about) wizard_about ;;
            reset) wizard_reset_state ;;
            exit)
                if state_has_progress && ! state_is_done finalize; then
                    if ! ui_confirm "Выйти из установщика" \
                        "Установка не завершена. Выйти? Состояние сохранится для продолжения." no; then
                        continue
                    fi
                fi
                return 0
                ;;
        esac
    done
}
