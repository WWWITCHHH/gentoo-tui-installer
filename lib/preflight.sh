# shellcheck shell=bash
# Live environment checks.

PREFLIGHT_LINES=()
PREFLIGHT_FAILED=0
PREFLIGHT_WARNED=0

preflight_line() {
    local level=$1 message=$2
    PREFLIGHT_LINES+=("${level}|${message}")
    case "$level" in
        fail) PREFLIGHT_FAILED=1 ;;
        warn) PREFLIGHT_WARNED=1 ;;
    esac
    log_info "preflight ${level}: ${message}"
}

preflight_required_commands() {
    local cmd missing=()
    local commands=(
        awk blkid blockdev chroot curl cut df find findmnt flock fold grep lsblk
        mkfs.ext4 mkfs.vfat mkswap mount mountpoint od parted partprobe readlink
        sed sha256sum sort stat swapon swapoff tar tee udevadm umount wc wipefs
        xargs xz
    )
    for cmd in "${commands[@]}"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        preflight_line fail "Нет обязательных команд: ${missing[*]}"
    else
        preflight_line ok "Обязательные утилиты Minimal CD доступны"
    fi

    local fs need_xfs=0 need_btrfs=0
    local -a filesystems=("$CFG_ROOT_FS")
    [[ $CFG_HOME_MODE == separate ]] && filesystems+=("$CFG_HOME_FS")
    [[ $CFG_BOOT_MODE == bios ]] && filesystems+=("$CFG_BOOT_FS")
    for fs in "${filesystems[@]}"; do
        case "$fs" in
            xfs) need_xfs=1 ;;
            btrfs) need_btrfs=1 ;;
        esac
    done
    if command_exists mkfs.xfs; then
        preflight_line ok "xfsprogs доступны"
    elif ((need_xfs)); then
        preflight_line fail "Выбрана XFS, но mkfs.xfs не найден"
    else
        preflight_line warn "mkfs.xfs не найден; XFS будет недоступен"
    fi
    if command_exists mkfs.btrfs; then
        preflight_line ok "btrfs-progs доступны"
    elif ((need_btrfs)); then
        preflight_line fail "Выбран Btrfs, но mkfs.btrfs не найден"
    else
        preflight_line warn "mkfs.btrfs не найден; Btrfs будет недоступен"
    fi
    if command_exists gpg; then
        if [[ -f /usr/share/openpgp-keys/gentoo-release.asc ]]; then
            preflight_line ok "GPG и ключ релизов Gentoo доступны"
        else
            preflight_line warn "GPG есть, но ключ релизов Gentoo не найден; будет проверена только SHA256"
        fi
    else
        preflight_line warn "GPG не найден; будет проверена только SHA256"
    fi
}

preflight_network() {
    local url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"
    local desktop_pending=0
    if desktop_is_enabled && ! state_is_done desktop; then
        desktop_pending=1
    fi
    if command_exists curl && curl -fsIL --max-time 12 "$url" >/dev/null 2>&1; then
        preflight_line ok "Сеть и доступ к distfiles.gentoo.org работают"
    elif state_is_done stage3 && state_is_done portage && state_is_done kernel &&
        state_is_done tools && state_is_done bootloader && ((!desktop_pending)); then
        preflight_line warn "Сеть недоступна, но все этапы, требующие загрузки пакетов, уже завершены"
    else
        preflight_line fail "Нет доступа к distfiles.gentoo.org; проверьте сеть Minimal CD"
    fi
}

preflight_clock() {
    local epoch year
    epoch=$(date +%s)
    year=$(date +%Y)
    if ((epoch < 1704067200)); then
        preflight_line fail "Системные часы установлены неверно (${year}); синхронизируйте время"
    elif ((epoch > 2208988800)); then
        preflight_line warn "Системные часы выглядят подозрительно (${year})"
    else
        preflight_line ok "Системная дата: $(date -u '+%Y-%m-%d %H:%M UTC')"
    fi
}

preflight_secure_boot() {
    local file state=""
    if [[ ! -d /sys/firmware/efi ]]; then
        return 0
    fi
    file=$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' -print -quit 2>/dev/null || true)
    if [[ -n $file ]]; then
        state=$(od -An -t u1 -- "$file" 2>/dev/null | awk '{print $NF; exit}')
    fi
    if [[ $state == 1 ]]; then
        preflight_line warn "Secure Boot включён. Неподписанный GRUB может не загрузиться; отключите Secure Boot"
    elif [[ $state == 0 ]]; then
        preflight_line ok "Secure Boot выключен"
    fi
}

preflight_uefi_variables() {
    if [[ -d /sys/firmware/efi ]]; then
        if [[ -d /sys/firmware/efi/efivars ]]; then
            preflight_line ok "UEFI-режим, efivars доступны"
        else
            preflight_line fail "UEFI-режим, но efivars не смонтированы"
        fi
    else
        preflight_line ok "BIOS/Legacy-режим"
    fi
}

preflight_disks() {
    local disks=("$@")
    if ((${#disks[@]} == 0)); then
        preflight_line fail "Не найдено ни одного целого диска"
        return
    fi
    if [[ -z $CFG_DISK ]]; then
        preflight_line warn "Найдено дисков: ${#disks[@]}; целевой диск ещё не выбран"
        return
    fi
    if validate_disk_device "$CFG_DISK" 2>/dev/null; then
        preflight_line ok "Найдено дисков: ${#disks[@]}; выбран ${CFG_DISK}"
    else
        preflight_line warn "Сохранённый диск ${CFG_DISK} не найден; выберите диск в параметрах"
    fi
}

preflight_workdir() {
    if [[ -w $GI_WORKDIR ]]; then
        preflight_line ok "Рабочий каталог: ${GI_WORKDIR}"
    else
        preflight_line fail "Рабочий каталог недоступен для записи: ${GI_WORKDIR}"
    fi
}

preflight_collect() {
    PREFLIGHT_LINES=()
    PREFLIGHT_FAILED=0
    PREFLIGHT_WARNED=0

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        preflight_line ok "Запуск от root"
    else
        preflight_line fail "Скрипт запущен не от root"
    fi
    if [[ $(uname -m) == x86_64 ]]; then
        preflight_line ok "Архитектура: x86_64 (amd64)"
    else
        preflight_line fail "Поддерживается только amd64/x86_64, найдено: $(uname -m)"
    fi
    preflight_uefi_variables
    preflight_required_commands
    preflight_clock
    preflight_network
    preflight_secure_boot
    preflight_workdir

    local -a disks=()
    mapfile -t disks < <(discover_disks 2>/dev/null || true)
    preflight_disks "${disks[@]}"
    if [[ -n $CFG_DISK && -b $CFG_DISK ]]; then
        local removable=0
        [[ -r /sys/block/${CFG_DISK##*/}/removable ]] &&
            read -r removable <"/sys/block/${CFG_DISK##*/}/removable" || true
        if [[ $removable == 1 ]]; then
            preflight_line warn "Целевой диск ${CFG_DISK} выглядит съёмным. Убедитесь, что это не установочный носитель"
        fi
    fi
}

preflight_render() {
    local entry level message symbol color
    ui_header "Проверка окружения" "Перед изменением диска установщик проверяет Minimal CD"
    for entry in "${PREFLIGHT_LINES[@]}"; do
        IFS='|' read -r level message <<<"$entry"
        case "$level" in
            ok) symbol="✓"; color=$C_GREEN ;;
            warn) symbol="!"; color=$C_YELLOW ;;
            fail) symbol="✖"; color=$C_RED ;;
        esac
        printf '  %s%s%s %s\n' "$color" "$symbol" "$C_RESET" "$message"
    done
    printf '\n'
    if ((PREFLIGHT_FAILED)); then
        ui_footer "Есть критические проблемы. Enter — выйти"
        ui_read_key || true
        return 1
    fi
    ui_footer "Enter — продолжить · Esc — выйти"
    if ! ui_read_key; then
        return 1
    fi
    [[ $UI_KEY != esc ]]
}

preflight_run() {
    preflight_collect
    if ((GI_ASSUME_YES)); then
        if ((PREFLIGHT_FAILED)); then
            log_error "preflight failed in assume-yes mode"
            return 1
        fi
        return 0
    fi
    preflight_render || return 1
    return 0
}

preflight_install_media_warning() {
    local body
    body="Этот установщик СОЗДАЁТ И УДАЛЯЕТ РАЗДЕЛЫ И ФАЙЛОВЫЕ СИСТЕМЫ.

Резервная копия данных обязательна. Установщик не поддерживает
шифрование, LVM, RAID и автоматическую настройку dual boot.

Поддерживаются сценарии Gentoo Handbook:
  • UEFI + GPT, загрузчик GRUB (ESP в /efi)
  • BIOS + MBR, загрузчик GRUB (/boot)

Этапы: проверка → диск → stage3 → Portage → ядро → система
→ службы → загрузчик → графическое окружение → завершение.

Продолжайте только если понимаете последствия."
    ui_header "Важно"
    ui_wrap "$body"
    ui_footer "Enter — принять и продолжить · Esc — выйти"
    ui_read_key || return 1
    [[ $UI_KEY != esc ]]
}
