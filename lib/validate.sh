# shellcheck shell=bash
# Input and configuration validators.

VALIDATION_MESSAGE=""

fail_validation() {
    VALIDATION_MESSAGE=$*
    return 1
}

validation_error() {
    VALIDATION_ERRORS+=("$*")
    log_warn "validation: $*"
}

validate_hostname() {
    local name=$1
    [[ -n $name ]] || fail_validation "Имя хоста не может быть пустым." || return 1
    ((${#name} <= 253)) || fail_validation "Имя хоста длиннее 253 символов." || return 1
    [[ $name =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        fail_validation "Допустимы латинские буквы, цифры, точки и дефис." || return 1
    [[ $name != *..* ]] || fail_validation "Две точки подряд недопустимы." || return 1
    return 0
}

validate_username() {
    local name=$1
    [[ $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
        fail_validation "Имя: строчная латинская буква или _, до 32 символов." || return 1
    [[ $name != root ]] || fail_validation "Пользователь root уже существует." || return 1
    return 0
}

validate_timezone() {
    local zone=$1
    if [[ $zone == UTC ]]; then
        return 0
    fi
    [[ $zone =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)+$ ]] ||
        fail_validation "Часовой пояс должен иметь вид Europe/Moscow." || return 1
    [[ $zone != *..* ]] || fail_validation "Недопустимый часовой пояс." || return 1
    if [[ -e "$GI_ROOT/usr/share/zoneinfo/$zone" || -e "/usr/share/zoneinfo/$zone" ]]; then
        return 0
    fi
    fail_validation "Часовой пояс не найден в zoneinfo: $zone"
    return 1
}

validate_locale() {
    local locale=$1
    [[ $locale =~ ^([a-z]{2,3}_[A-Z]{2}\.UTF-8(@[a-z0-9]+)?|C\.UTF-8)$ ]] ||
        fail_validation "Используйте UTF-8 локаль, например ru_RU.UTF-8." || return 1
    return 0
}

validate_keymap() {
    local keymap=$1
    [[ $keymap =~ ^[A-Za-z0-9_-]+$ ]] ||
        fail_validation "Раскладка: только буквы, цифры, _ и -." || return 1
    return 0
}

validate_nonempty() {
    [[ -n ${1:-} ]] || fail_validation "Значение не может быть пустым." || return 1
    return 0
}

validate_mib() {
    local value=$1
    [[ $value =~ ^[0-9]+$ ]] || fail_validation "Введите целое число MiB." || return 1
    ((value > 0)) || fail_validation "Размер должен быть больше нуля." || return 1
    return 0
}

validate_int_range() {
    local value=$1 min=$2 max=$3
    [[ $value =~ ^[0-9]+$ ]] || fail_validation "Введите целое число." || return 1
    ((value >= min && value <= max)) || fail_validation "Допустимый диапазон: ${min}..${max}." || return 1
    return 0
}

validate_url() {
    local url=$1
    [[ $url =~ ^https?://[^[:space:]]+$ ]] ||
        fail_validation "URL должен начинаться с http:// или https://." || return 1
    return 0
}

validate_optional_url() {
    [[ -z ${1:-} ]] && return 0
    validate_url "$1"
}

validate_disk_device() {
    local disk=$1
    [[ $disk == /dev/* ]] || fail_validation "Укажите блочное устройство в /dev." || return 1
    [[ -b $disk ]] || fail_validation "Устройство не найдено: $disk" || return 1
    [[ $(lsblk -dno TYPE -- "$disk" 2>/dev/null) == disk ]] ||
        fail_validation "Это не целый диск: $disk" || return 1
    return 0
}

validate_root_fs() {
    case "$1" in
        xfs|ext4|btrfs) return 0 ;;
        *) fail_validation "Поддерживаются xfs, ext4 и btrfs."; return 1 ;;
    esac
}

validate_bool() {
    case "$1" in
        yes|no) return 0 ;;
        *) fail_validation "Ожидается yes или no."; return 1 ;;
    esac
}

validate_no_control() {
    local value=$1
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *'"'* ]] ||
        fail_validation "Значение содержит недопустимые символы." || return 1
    return 0
}

validate_use_flags() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9_@+.-]*(\ [A-Za-z0-9_@+.-]+)*$ ]] ||
        fail_validation "USE-флаги: через пробел, без кавычек и спецсимволов." || return 1
    return 0
}

validate_optional_tokens() {
    [[ -z ${1:-} ]] && return 0
    validate_use_flags "$1"
}

validate_kernel_cmdline() {
    local value=$1
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *'"'* ]] ||
        fail_validation "Командная строка ядра содержит недопустимые символы." || return 1
    # /etc/default/grub is sourced as a shell script. Reject characters that
    # could expand there even though the value is also single-quoted.
    [[ $value != *'$'* && $value != *'`'* && $value != *'\'* ]] ||
        fail_validation 'Командная строка ядра не должна содержать $, ` или \.' || return 1
    return 0
}

validate_cflags() {
    local value=$1
    [[ -n $value ]] || fail_validation "CFLAGS не могут быть пустыми." || return 1
    [[ $value != *$'\n'* && $value != *$'\r'* && $value != *'"'* ]] ||
        fail_validation "CFLAGS содержит недопустимые символы." || return 1
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

    [[ $CFG_BOOT_MODE == uefi || $CFG_BOOT_MODE == bios ]] ||
        validation_error "Режим загрузки: uefi или bios."
    if [[ $CFG_BOOT_MODE == uefi && ! -d /sys/firmware/efi ]]; then
        validation_error "Выбран UEFI, но Minimal CD загружен в BIOS-режиме. Перезагрузите CD в UEFI."
    fi
    if [[ $CFG_BOOT_MODE == bios && -d /sys/firmware/efi ]]; then
        validation_error "Выбран BIOS, но Minimal CD загружен в UEFI-режиме."
    fi

    [[ $CFG_DISK_MODE == auto || $CFG_DISK_MODE == manual ]] ||
        validation_error "Режим разметки: auto или manual."

    if [[ $CFG_DISK_MODE == auto ]]; then
        if ! validate_disk_device "$CFG_DISK" 2>/dev/null; then
            validation_error "Не выбран корректный целевой диск."
        else
            disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
            if ((disk_mib < 16384)); then
                validation_error "Диск меньше 16 GiB: установка Gentoo может не поместиться."
            fi
            if [[ $CFG_BOOT_MODE == bios ]] && ((disk_mib > 2097152)); then
                validation_error "BIOS + MBR не поддерживает диски больше 2 TiB; используйте UEFI + GPT."
            fi
            if ! disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" >/dev/null 2>&1; then
                validation_error "Недостаточно места для выбранной схемы: ${PLAN_ERROR:-ошибка плана}."
            fi
            if [[ $CFG_HOME_MODE == separate ]]; then
                validate_mib "$CFG_HOME_MIB" 2>/dev/null ||
                    validation_error "Размер /home должен быть целым числом MiB."
            fi
        fi
    else
        validate_disk_device "$CFG_DISK" 2>/dev/null ||
            validation_error "Для ручной схемы не выбран корректный диск."
        [[ -n $CFG_PART_ROOT && -b $CFG_PART_ROOT ]] ||
            validation_error "Для ручной схемы не выбрана корневая партиция."
        if [[ $CFG_BOOT_MODE == uefi ]]; then
            [[ -n $CFG_PART_ESP && -b $CFG_PART_ESP ]] ||
                validation_error "Для UEFI не выбран ESP."
        else
            [[ -n $CFG_PART_BOOT && -b $CFG_PART_BOOT ]] ||
                validation_error "Для BIOS не выбран раздел /boot."
        fi
        if [[ -n $CFG_PART_HOME && -b $CFG_PART_HOME ]]; then
            :
        elif [[ $CFG_HOME_MODE == separate ]]; then
            validation_error "Не выбран раздел /home."
        fi
        if [[ -b $CFG_DISK ]] && [[ $CFG_BOOT_MODE == bios ]]; then
            disk_mib=$(disk_size_mib "$CFG_DISK" 2>/dev/null || printf '0')
            if ((disk_mib > 2097152)); then
                validation_error "BIOS + MBR не поддерживает диски больше 2 TiB; используйте UEFI + GPT."
            fi
        fi
        local -A seen_parts=()
        local part parent="" current_parent
        for part in "$CFG_PART_ROOT" "$CFG_PART_ESP" "$CFG_PART_BOOT" \
            "$CFG_PART_SWAP" "$CFG_PART_HOME"; do
            [[ -n $part ]] || continue
            if [[ -n ${seen_parts[$part]+set} ]]; then
                validation_error "Раздел ${part} назначен нескольким ролям."
            else
                seen_parts[$part]=1
            fi
            [[ -b $part ]] || continue
            current_parent=$(lsblk -no PKNAME -- "$part" 2>/dev/null | head -n 1)
            [[ -n $current_parent ]] || continue
            if [[ -z $parent ]]; then
                parent=$current_parent
            elif [[ $parent != "$current_parent" ]]; then
                validation_error "Все разделы ручной схемы должны находиться на одном диске."
                break
            fi
        done
        if [[ -n $parent && -n $CFG_DISK && ${CFG_DISK##*/} != "$parent" ]]; then
            validation_error "Разделы относятся к /dev/${parent}, а выбран диск ${CFG_DISK}."
        fi
    fi

    validate_root_fs "$CFG_ROOT_FS" 2>/dev/null ||
        validation_error "Файловая система root: xfs, ext4 или btrfs."
    validate_root_fs "$CFG_HOME_FS" 2>/dev/null ||
        validation_error "Файловая система /home: xfs, ext4 или btrfs."
    if [[ $CFG_BOOT_MODE == bios ]]; then
        validate_root_fs "$CFG_BOOT_FS" 2>/dev/null ||
            validation_error "Файловая система /boot: xfs, ext4 или btrfs."
    fi
    case "$CFG_SWAP_MODE" in
        auto|none) ;;
        custom)
            validate_mib "$CFG_SWAP_MIB" 2>/dev/null ||
                validation_error "Пользовательский размер swap должен быть больше нуля."
            ;;
        *) validation_error "Режим swap: auto, none или custom." ;;
    esac
    [[ $CFG_HOME_MODE == no || $CFG_HOME_MODE == separate ]] ||
        validation_error "Режим /home: no или separate."

    case "$CFG_STAGE_FLAVOR" in
        openrc|systemd|desktop-openrc|desktop-systemd) ;;
        *) validation_error "Неизвестный вариант stage3." ;;
    esac
    validate_url "$CFG_MIRROR" 2>/dev/null ||
        validation_error "Некорректный URL зеркала."
    if [[ -n $CFG_STAGE_URL ]]; then
        validate_url "$CFG_STAGE_URL" 2>/dev/null ||
            validation_error "Некорректный URL stage3."
    fi

    case "$CFG_PROFILE" in
        stage|desktop|gnome|kde|hardened) ;;
        *) validation_error "Неизвестный профиль Portage." ;;
    esac

    case "$CFG_KERNEL_MODE" in
        bin|dist|manual) ;;
        *) validation_error "Неизвестный метод установки ядра." ;;
    esac

    case "$CFG_MICROCODE" in
        auto|none|intel|amd) ;;
        *) validation_error "Микрокод: auto, none, intel или amd." ;;
    esac

    [[ $CFG_BOOTLOADER == grub ]] ||
        validation_error "В этой версии поддерживается только GRUB."

    validate_hostname "$CFG_HOSTNAME" 2>/dev/null ||
        validation_error "Имя хоста: ${VALIDATION_MESSAGE:-некорректно}."
    validate_timezone "$CFG_TIMEZONE" 2>/dev/null ||
        validation_error "Часовой пояс: ${VALIDATION_MESSAGE:-некорректно}."
    validate_locale "$CFG_LOCALE" 2>/dev/null ||
        validation_error "Локаль: ${VALIDATION_MESSAGE:-некорректна}."
    validate_keymap "$CFG_KEYMAP" 2>/dev/null ||
        validation_error "Раскладка: ${VALIDATION_MESSAGE:-некорректна}."
    case "$CFG_NETWORK" in
        dhcpcd|networkmanager|none) ;;
        *) validation_error "Неизвестный способ настройки сети." ;;
    esac
    case "$CFG_HWCLOCK" in
        UTC|local) ;;
        *) validation_error "Часы: UTC или local." ;;
    esac
    validate_username "$CFG_USERNAME" 2>/dev/null ||
        validation_error "Пользователь: ${VALIDATION_MESSAGE:-некорректен}."
    validate_cflags "$CFG_CFLAGS" 2>/dev/null ||
        validation_error "CFLAGS: ${VALIDATION_MESSAGE:-некорректны}."
    validate_use_flags "$CFG_USE_EXTRA" 2>/dev/null ||
        validation_error "USE: ${VALIDATION_MESSAGE:-некорректны}."
    validate_optional_tokens "$CFG_VIDEO_CARDS" 2>/dev/null ||
        validation_error "VIDEO_CARDS: ${VALIDATION_MESSAGE:-некорректны}."
    validate_kernel_cmdline "$CFG_KERNEL_CMDLINE" 2>/dev/null ||
        validation_error "Kernel cmdline: ${VALIDATION_MESSAGE:-некорректна}."

    for flag in CFG_FIRMWARE CFG_CPU_FLAGS CFG_UPDATE_WORLD CFG_SSH CFG_CRON \
        CFG_CHRONY CFG_SYSLOG CFG_SUDO CFG_CREATE_USER CFG_FORMAT_ESP \
        CFG_FORMAT_BOOT CFG_FORMAT_SWAP CFG_FORMAT_ROOT CFG_FORMAT_HOME; do
        validate_bool "${!flag}" 2>/dev/null ||
            validation_error "${flag}: ${VALIDATION_MESSAGE:-ожидается yes/no}."
    done

    if [[ $CFG_MAKE_JOBS != auto ]]; then
        validate_int_range "$CFG_MAKE_JOBS" 1 256 2>/dev/null ||
            validation_error "MAKEOPTS: ${VALIDATION_MESSAGE:-некорректен}."
    fi

    ((${#VALIDATION_ERRORS[@]} == 0))
}
