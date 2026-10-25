# shellcheck shell=bash
# Disk discovery, layout planning and partitioning.

PLAN_COUNT=0
PLAN_TOTAL_MIB=0
PLAN_ERROR=""
PLAN_NUM=() PLAN_ROLE=() PLAN_SIZE=() PLAN_START=() PLAN_END=()
PLAN_FSTYPE=() PLAN_MOUNT=() PLAN_LABEL=()
PLAN_SWAP_MIB=0
PLAN_HOME_MIB=0

discover_disks() {
    local name type
    while read -r name type; do
        [[ $type == disk ]] || continue
        case "$name" in
            /dev/loop*|/dev/zram*|/dev/sr*|/dev/ram*) continue ;;
        esac
        printf '%s\n' "$name"
    done < <(lsblk -dpno NAME,TYPE 2>/dev/null | sort)
}

disk_size_mib() {
    local disk=$1 bytes
    bytes=$(blockdev --getsize64 -- "$disk" 2>/dev/null) || return 1
    printf '%d' "$((bytes / 1024 / 1024))"
}

disk_model() {
    local model
    model=$(lsblk -dno MODEL -- "$1" 2>/dev/null || true)
    trim "${model:-неизвестно}"
}

disk_is_removable() {
    local name=${1##*/} value=0
    [[ -r /sys/block/${name}/removable ]] && read -r value <"/sys/block/${name}/removable" || true
    [[ $value == 1 ]]
}

plan_reset() {
    PLAN_COUNT=0
    PLAN_ERROR=""
    PLAN_NUM=() PLAN_ROLE=() PLAN_SIZE=() PLAN_START=() PLAN_END=()
    PLAN_FSTYPE=() PLAN_MOUNT=() PLAN_LABEL=()
    PLAN_SWAP_MIB=0
    PLAN_HOME_MIB=0
}

_plan_add() {
    local role=$1 size=$2 fstype=$3 mount=$4 label=$5
    local start end num
    if ((size <= 0)); then
        PLAN_ERROR="размер раздела ${role} должен быть больше нуля"
        return 1
    fi
    if ((PLAN_COUNT == 0)); then
        start=1
    else
        start=${PLAN_END[PLAN_COUNT - 1]}
    fi
    end=$((start + size))
    if ((end > PLAN_TOTAL_MIB - 1)); then
        PLAN_ERROR="раздел ${role} не помещается на диск"
        return 1
    fi
    num=$((PLAN_COUNT + 1))
    PLAN_NUM[num - 1]=$num
    PLAN_ROLE[num - 1]=$role
    PLAN_SIZE[num - 1]=$size
    PLAN_START[num - 1]=$start
    PLAN_END[num - 1]=$end
    PLAN_FSTYPE[num - 1]=$fstype
    PLAN_MOUNT[num - 1]=$mount
    PLAN_LABEL[num - 1]=$label
    PLAN_COUNT=$num
}

# Builds a plan matching the two layouts from the Gentoo AMD64 Handbook.
# UEFI:  ESP 1 GiB + [swap] + root + [/home]
# BIOS:  /boot 1 GiB + [swap] + root + [/home]
disk_plan_build() {
    local boot_mode=$1 disk_mib=$2
    local swap_mib=0 home_mib=0 min_root=8192
    local root_size home_start i
    plan_reset
    PLAN_TOTAL_MIB=$disk_mib
    if ((disk_mib < 4096)); then
        PLAN_ERROR="диск слишком мал (${disk_mib} MiB)"
        return 1
    fi
    if [[ $boot_mode == bios ]] && ((disk_mib > 2097152)); then
        PLAN_ERROR="BIOS + MBR не поддерживает диски больше 2 TiB"
        return 1
    fi

    case "$CFG_SWAP_MODE" in
        auto) swap_mib=$(suggest_swap_mib) ;;
        none) swap_mib=0 ;;
        custom) swap_mib=${CFG_SWAP_MIB:-0} ;;
        *) PLAN_ERROR="неизвестный режим swap"; return 1 ;;
    esac
    if [[ $CFG_HOME_MODE == separate ]]; then
        home_mib=${CFG_HOME_MIB:-0}
        if ((home_mib <= 0)); then
            PLAN_ERROR="размер /home должен быть больше нуля"
            return 1
        fi
    fi
    PLAN_SWAP_MIB=$swap_mib
    PLAN_HOME_MIB=$home_mib

    if [[ $boot_mode == uefi ]]; then
        _plan_add esp 1024 vfat /efi "EFI" || return 1
    elif [[ $boot_mode == bios ]]; then
        _plan_add boot 1024 "$CFG_BOOT_FS" /boot "boot" || return 1
    else
        PLAN_ERROR="неизвестный режим загрузки"
        return 1
    fi
    if ((swap_mib > 0)); then
        _plan_add swap "$swap_mib" swap none "swap" || return 1
    fi

    if ((home_mib > 0)); then
        local fixed_used=1024
        ((swap_mib > 0)) && fixed_used=$((fixed_used + swap_mib))
        home_start=$((PLAN_TOTAL_MIB - 1 - home_mib))
        root_size=$((home_start - 1 - fixed_used))
        if ((root_size < min_root)); then
            PLAN_ERROR="root меньше ${min_root} MiB; уменьшите swap или /home"
            return 1
        fi
        _plan_add root "$root_size" "$CFG_ROOT_FS" / "root" || return 1
        _plan_add home "$home_mib" "$CFG_HOME_FS" /home "home" || return 1
    else
        local used=1
        for ((i = 0; i < PLAN_COUNT; i++)); do
            used=$((used + PLAN_SIZE[i]))
        done
        root_size=$((PLAN_TOTAL_MIB - 1 - used))
        if ((root_size < min_root)); then
            PLAN_ERROR="root меньше ${min_root} MiB; уменьшите swap"
            return 1
        fi
        _plan_add root "$root_size" "$CFG_ROOT_FS" / "root" || return 1
    fi
    return 0
}

plan_partition_path() {
    local index=$1
    part_path "$CFG_DISK" "${PLAN_NUM[$index]}"
}

disk_plan_print() {
    local i path
    printf 'Схема: %s\n' "$([[ $CFG_BOOT_MODE == uefi ]] && printf 'UEFI + GPT' || printf 'BIOS + MBR')"
    printf 'Диск:  %s (%s, %s)\n' "$CFG_DISK" "$(disk_model "$CFG_DISK")" "$(human_mib "$PLAN_TOTAL_MIB")"
    printf '\n'
    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        printf '  %-12s %-8s %-7s %-6s %s\n' \
            "$path" "${PLAN_LABEL[$i]}" "${PLAN_FSTYPE[$i]}" \
            "$(human_mib "${PLAN_SIZE[$i]}")" "${PLAN_MOUNT[$i]/none/—}"
    done
    printf '\n'
    printf 'Изменения уничтожат ВСЕ данные на %s.\n' "$CFG_DISK"
}

disk_plan_markdown() {
    local i path
    printf '## План разметки\n\n'
    printf '| Раздел | Роль | ФС | Размер | Точка монтирования |\n'
    printf '|---|---|---|---:|---|\n'
    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        printf '| `%s` | %s | %s | %s | `%s` |\n' \
            "$path" "${PLAN_ROLE[$i]}" "${PLAN_FSTYPE[$i]}" \
            "$(human_mib "${PLAN_SIZE[$i]}")" "${PLAN_MOUNT[$i]}"
    done
    printf '\n'
}

disks_select_disk() {
    local -a entries=() tags=() labels=()
    local disk size model transport removable label default=""
    mapfile -t entries < <(discover_disks)
    ((${#entries[@]} > 0)) || return 1
    for disk in "${entries[@]}"; do
        size=$(lsblk -dno SIZE -- "$disk" 2>/dev/null | xargs)
        model=$(disk_model "$disk")
        transport=$(lsblk -dno TRAN -- "$disk" 2>/dev/null | xargs)
        removable=""
        disk_is_removable "$disk" && removable=" · съёмный"
        label="${disk} — ${size} · ${model}${transport:+ · $transport}${removable}"
        tags+=("$disk")
        labels+=("${disk}|${label}|$(human_mib "$(disk_size_mib "$disk")")")
        [[ $disk == "$CFG_DISK" ]] && default=$disk
    done
    [[ -z $default ]] && default=${tags[0]}
    if ui_menu "Целевой диск" "Все разделы и подписи на выбранном диске будут уничтожены" \
        "$default" "${labels[@]}"; then
        CFG_DISK=$UI_RESULT
        return 0
    fi
    return 1
}

disks_disk_mounted() {
    local mountpoints
    mountpoints=$(lsblk -nrno MOUNTPOINTS -- "$CFG_DISK" 2>/dev/null | grep -v '^$' || true)
    [[ -n $mountpoints ]]
}

disks_check_target() {
    if ! validate_disk_device "$CFG_DISK" 2>/dev/null; then
        ui_error "Некорректный диск" "$VALIDATION_MESSAGE"
        return 1
    fi
    if disks_disk_mounted; then
        ui_error "Диск уже используется" \
            "На ${CFG_DISK} есть смонтированные разделы. Размонтируйте их перед установкой."
        return 1
    fi
    local swaps
    swaps=$(lsblk -nrno NAME -- "$CFG_DISK" 2>/dev/null | while read -r name; do
        grep -q "^/dev/${name}[[:space:]]" /proc/swaps 2>/dev/null && printf '%s\n' "$name"
    done)
    if [[ -n $swaps ]]; then
        ui_error "Активный swap" "Отключите swap на ${CFG_DISK}: swapoff -a"
        return 1
    fi
    return 0
}

disks_validate_erase() {
    [[ $1 == ERASE ]] && return 0
    VALIDATION_MESSAGE="Введите ERASE заглавными буквами для подтверждения."
    return 1
}

disks_confirm_destruction() {
    local plan
    if ((GI_ASSUME_YES)); then
        log_warn "destructive confirmation skipped (--yes)"
        return 0
    fi
    plan=$(disk_plan_print)
    ui_header "Последнее предупреждение" "Данные на диске будут безвозвратно уничтожены"
    ui_wrap "$plan"
    printf '\n'
    ui_input "Подтверждение" "Введите ERASE, чтобы начать разметку и форматирование:" \
        "" disks_validate_erase "Это действие необратимо" no
}

disk_format_fs() {
    local fstype=$1 device=$2 label=$3
    ui_run "Стирание подписей: $device" wipefs -a "$device" || return 1
    case "$fstype" in
        vfat)
            ui_run "FAT32: $device" mkfs.vfat -F 32 -n "$label" "$device" || return 1
            ;;
        xfs)
            ui_run "XFS: $device" mkfs.xfs -f -L "$label" "$device" || return 1
            ;;
        ext4)
            ui_run "ext4: $device" mkfs.ext4 -F -L "$label" -m 1 "$device" || return 1
            ;;
        btrfs)
            ui_run "Btrfs: $device" mkfs.btrfs -f -L "$label" "$device" || return 1
            ;;
        swap)
            ui_run "swap: $device" mkswap -L "$label" "$device" || return 1
            ;;
        *)
            die "неизвестная файловая система: $fstype"
            ;;
    esac
}

parted_fs_type() {
    case "$1" in
        vfat) printf 'fat32' ;;
        swap) printf 'linux-swap' ;;
        *) printf '%s' "$1" ;;
    esac
}

disks_create_auto_table() {
    local label_type="gpt" i path role fstype part_type
    local -a cmd=(parted --script --align optimal "$CFG_DISK" mklabel gpt)
    if [[ $CFG_BOOT_MODE == bios ]]; then
        label_type="msdos"
        cmd=(parted --script --align optimal "$CFG_DISK" mklabel msdos)
    fi
    ui_run "Создание таблицы ${label_type^^}" "${cmd[@]}" || return 1

    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        role=${PLAN_ROLE[$i]}
        fstype=${PLAN_FSTYPE[$i]}
        part_type=$(parted_fs_type "$fstype")
        if [[ $CFG_BOOT_MODE == uefi ]]; then
            ui_run "Раздел ${path}: ${role}" parted --script --align optimal "$CFG_DISK" \
                mkpart "${PLAN_LABEL[$i]}" "$part_type" "${PLAN_START[$i]}MiB" "${PLAN_END[$i]}MiB" || return 1
            if [[ $role == esp ]]; then
                ui_run "Флаг ESP" parted --script "$CFG_DISK" set "${PLAN_NUM[$i]}" esp on || return 1
            fi
        else
            ui_run "Раздел ${path}: ${role}" parted --script --align optimal "$CFG_DISK" \
                mkpart primary "$part_type" "${PLAN_START[$i]}MiB" "${PLAN_END[$i]}MiB" || return 1
        fi
    done
    if [[ $CFG_BOOT_MODE == bios ]]; then
        ui_run "Флаг boot" parted --script "$CFG_DISK" set 1 boot on || return 1
    fi
    ui_run "Обновление таблицы разделов" partprobe "$CFG_DISK" || return 1
    ui_run "Ожидание udev" udevadm settle || true
    local attempt all_ready
    for attempt in {1..20}; do
        all_ready=1
        for ((i = 0; i < PLAN_COUNT; i++)); do
            path=$(plan_partition_path "$i")
            [[ -b $path ]] || all_ready=0
        done
        ((all_ready == 1)) && break
        sleep 1
    done
    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        if [[ ! -b $path ]]; then
            die "ядро не обнаружило созданный раздел $path"
        fi
    done
}

disks_format_auto() {
    local i path role fstype label
    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        role=${PLAN_ROLE[$i]}
        fstype=${PLAN_FSTYPE[$i]}
        case "$role" in
            esp) label="EFI" ;;
            boot) label="boot" ;;
            swap) label="swap" ;;
            root) label="root" ;;
            home) label="home" ;;
            *) label=$role ;;
        esac
        disk_format_fs "$fstype" "$path" "$label" || return 1
    done
}

disks_capture_auto_paths() {
    local i path role
    CFG_PART_ESP="" CFG_PART_BOOT="" CFG_PART_SWAP="" CFG_PART_ROOT="" CFG_PART_HOME=""
    CFG_FORMAT_ESP=yes CFG_FORMAT_BOOT=yes CFG_FORMAT_SWAP=yes
    CFG_FORMAT_ROOT=yes CFG_FORMAT_HOME=yes
    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        role=${PLAN_ROLE[$i]}
        case "$role" in
            esp) CFG_PART_ESP=$path ;;
            boot) CFG_PART_BOOT=$path; CFG_BOOT_FS=${PLAN_FSTYPE[$i]} ;;
            swap) CFG_PART_SWAP=$path ;;
            root) CFG_PART_ROOT=$path ;;
            home) CFG_PART_HOME=$path ;;
        esac
    done
}

disk_partition_auto() {
    local disk_mib
    disk_mib=$(disk_size_mib "$CFG_DISK") || die "не удалось определить размер ${CFG_DISK}"
    disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" || die "план разметки: ${PLAN_ERROR}"
    disks_confirm_destruction || return 1
    disks_create_auto_table || return 1
    disks_format_auto || return 1
    disks_capture_auto_paths
    disks_capture_uuids || return 1
    config_save
    disks_mount_all || return 1
}

# ---------------------------------------------------------------------------
# Manual layout
# ---------------------------------------------------------------------------

disks_partition_menu_items() {
    local line name size fstype type mountpoints label
    while IFS= read -r line; do
        name="" size="" fstype="" type="" mountpoints=""
        [[ $line =~ NAME=\"([^\"]*)\" ]] && name=${BASH_REMATCH[1]}
        [[ $line =~ SIZE=\"([^\"]*)\" ]] && size=${BASH_REMATCH[1]}
        [[ $line =~ FSTYPE=\"([^\"]*)\" ]] && fstype=${BASH_REMATCH[1]}
        [[ $line =~ TYPE=\"([^\"]*)\" ]] && type=${BASH_REMATCH[1]}
        [[ $line =~ MOUNTPOINTS=\"([^\"]*)\" ]] && mountpoints=${BASH_REMATCH[1]}
        [[ $type == part ]] || continue
        label="${name} — ${size} — ${fstype:-нет ФС}"
        [[ -n $mountpoints ]] && label+=" — ${mountpoints}"
        printf '%s|%s|\n' "$name" "$label"
    done < <(lsblk -Ppno NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS -- "$CFG_DISK" 2>/dev/null)
}

disks_choose_fs() {
    local title=$1 default=$2
    ui_menu "$title" "Файловая система будет создана заново" "$default" \
        "xfs|XFS|Надёжная ФС по умолчанию, рекомендуется для Gentoo" \
        "ext4|ext4|Классическая и предсказуемая ФС" \
        "btrfs|Btrfs|Снапшоты и сжатие; subvolumes не настраиваются" || return 1
}

disks_choose_partition() {
    local title=$1 role=$2 allow_none=${3:-no}
    local -a items=() entries=()
    local default var used
    while :; do
        mapfile -t entries < <(disks_partition_menu_items)
        if ((${#entries[@]} == 0)); then
            ui_error "Разделы не найдены" "Создайте разделы на ${CFG_DISK} и повторите выбор."
            return 1
        fi
        items=("${entries[@]}")
        if [[ $allow_none == yes ]]; then
            items+=("none|Не использовать|Без отдельного раздела")
        fi
        default=${!role}
        if [[ -z $default ]]; then
            if [[ $allow_none == yes ]]; then
                default=none
            else
                default=${items[0]%%|*}
            fi
        fi
        ui_menu "$title" "Выберите раздел для роли ${role}" "$default" "${items[@]}" || return 1
        [[ $UI_RESULT == none ]] && return 2

        used=0
        for var in CFG_PART_ESP CFG_PART_BOOT CFG_PART_SWAP CFG_PART_ROOT CFG_PART_HOME; do
            [[ $var == "$role" ]] && continue
            if [[ ${!var} == "$UI_RESULT" ]]; then
                used=1
                break
            fi
        done
        if ((used)); then
            ui_error "Раздел уже используется" "Один раздел нельзя назначить двум ролям."
            continue
        fi
        printf -v "$role" '%s' "$UI_RESULT"
        return 0
    done
}

disks_manual_assign() {
    if [[ -z $CFG_DISK || ! -b $CFG_DISK ]]; then
        disks_select_disk || return 1
    fi
    disks_check_target || return 1

    if command_exists cfdisk; then
        if ui_confirm "Ручная разметка" \
            "Открыть cfdisk для ${CFG_DISK}?

Создайте разделы заранее. После выхода назначьте их ролям.
UEFI: нужен ESP (vfat). BIOS: нужен /boot (ext4/xfs/btrfs)." no; then
            ui_interactive "cfdisk ${CFG_DISK}" cfdisk "$CFG_DISK" || return 1
            ui_run "Обновление таблицы разделов" partprobe "$CFG_DISK" || true
            ui_run "Ожидание udev" udevadm settle || true
        fi
    fi

    CFG_PART_ESP="" CFG_PART_BOOT="" CFG_PART_SWAP="" CFG_PART_ROOT="" CFG_PART_HOME=""
    disks_choose_partition "Корневой раздел" CFG_PART_ROOT no || return 1
    if [[ $CFG_BOOT_MODE == uefi ]]; then
        disks_choose_partition "EFI System Partition" CFG_PART_ESP no || return 1
    else
        disks_choose_partition "Раздел /boot" CFG_PART_BOOT no || return 1
    fi
    local result=0
    disks_choose_partition "Swap (необязательно)" CFG_PART_SWAP yes || result=$?
    if ((result == 1)); then
        return 1
    fi
    CFG_HOME_MODE=no
    if ui_confirm "Отдельный /home" "Создать отдельный раздел /home?" no; then
        disks_choose_partition "Раздел /home" CFG_PART_HOME no || return 1
        CFG_HOME_MODE=separate
    fi

    local disk_name="" part
    for part in "$CFG_PART_ROOT" "$CFG_PART_ESP" "$CFG_PART_BOOT" "$CFG_PART_SWAP" "$CFG_PART_HOME"; do
        [[ -n $part ]] || continue
        local parent
        parent=$(lsblk -no PKNAME -- "$part" 2>/dev/null | head -n1)
        if [[ -z $disk_name ]]; then
            disk_name=$parent
        elif [[ $disk_name != "$parent" ]]; then
            ui_error "Разные диски" "Все выбранные разделы должны находиться на одном диске."
            return 1
        fi
    done
    if [[ -z $disk_name ]]; then
        ui_error "Не удалось определить диск" "Разделы не связаны с целым диском."
        return 1
    fi
    CFG_DISK="/dev/${disk_name#/dev/}"

    local ptt
    ptt=$(lsblk -dno PTTYPE -- "$CFG_DISK" 2>/dev/null | xargs)
    if [[ $CFG_BOOT_MODE == uefi && $ptt != gpt ]]; then
        ui_error "Нужна GPT" "UEFI-схема в установщике требует GPT (найдено: ${ptt:-нет})."
        return 1
    fi
    if [[ $CFG_BOOT_MODE == bios && $ptt != dos ]]; then
        ui_error "Нужна MBR" "BIOS-схема в установщике требует MBR/DOS (найдено: ${ptt:-нет})."
        return 1
    fi
    return 0
}

disks_manual_options() {
    local fs
    ui_header "Разделы и файловые системы" "Форматирование уничтожает данные на выбранных разделах"
    ui_wrap "root: ${CFG_PART_ROOT}
ESP: ${CFG_PART_ESP:-—}
/boot: ${CFG_PART_BOOT:-—}
swap: ${CFG_PART_SWAP:-—}
/home: ${CFG_PART_HOME:-—}"
    printf '\n'

    if ! disks_choose_fs "Файловая система root" "$CFG_ROOT_FS"; then
        return 1
    fi
    CFG_ROOT_FS=$UI_RESULT
    CFG_FORMAT_ROOT=yes

    if [[ $CFG_BOOT_MODE == uefi ]]; then
        if ui_confirm "Форматировать ESP?" \
            "Переформатировать ${CFG_PART_ESP} в FAT32? Для dual boot обычно НЕТ." no; then
            CFG_FORMAT_ESP=yes
        else
            CFG_FORMAT_ESP=no
            fs=$(fs_type "$CFG_PART_ESP")
            if [[ $fs != vfat ]]; then
                ui_error "ESP не vfat" "Раздел ${CFG_PART_ESP} должен содержать FAT32 (найдено: ${fs:-нет})."
                return 1
            fi
        fi
    else
        if ui_confirm "Форматировать /boot?" "Переформатировать ${CFG_PART_BOOT}?" yes; then
            CFG_FORMAT_BOOT=yes
            if ! disks_choose_fs "Файловая система /boot" "$CFG_BOOT_FS"; then
                return 1
            fi
            CFG_BOOT_FS=$UI_RESULT
        else
            CFG_FORMAT_BOOT=no
            fs=$(fs_type "$CFG_PART_BOOT")
            case "$fs" in
                ext4|xfs|btrfs) CFG_BOOT_FS=$fs ;;
                *)
                    ui_error "Некорректный /boot" "Файловая система ${CFG_PART_BOOT}: ${fs:-нет}."
                    return 1
                    ;;
            esac
        fi
    fi

    if [[ -n $CFG_PART_SWAP ]]; then
        if ui_confirm "Форматировать swap?" "Выполнить mkswap для ${CFG_PART_SWAP}?" yes; then
            CFG_FORMAT_SWAP=yes
            CFG_SWAP_MODE=custom
            CFG_SWAP_MIB=$(( $(blockdev --getsize64 -- "$CFG_PART_SWAP" 2>/dev/null || printf '0') / 1024 / 1024 ))
        else
            CFG_FORMAT_SWAP=no
            fs=$(fs_type "$CFG_PART_SWAP")
            if [[ $fs != swap ]]; then
                ui_error "Это не swap" "Раздел ${CFG_PART_SWAP} не содержит swap (найдено: ${fs:-нет})."
                return 1
            fi
            CFG_SWAP_MODE=custom
            CFG_SWAP_MIB=$(( $(blockdev --getsize64 -- "$CFG_PART_SWAP" 2>/dev/null || printf '0') / 1024 / 1024 ))
        fi
    else
        CFG_FORMAT_SWAP=no
        CFG_SWAP_MODE=none
        CFG_SWAP_MIB=0
    fi

    if [[ -n $CFG_PART_HOME ]]; then
        CFG_HOME_MODE=separate
        if ui_confirm "Форматировать /home?" "Форматирование ${CFG_PART_HOME} уничтожит данные." no; then
            CFG_FORMAT_HOME=yes
            if ! disks_choose_fs "Файловая система /home" "$CFG_HOME_FS"; then
                return 1
            fi
            CFG_HOME_FS=$UI_RESULT
        else
            CFG_FORMAT_HOME=no
            fs=$(fs_type "$CFG_PART_HOME")
            case "$fs" in
                ext4|xfs|btrfs) CFG_HOME_FS=$fs ;;
                *)
                    ui_error "Некорректный /home" "Файловая система ${CFG_PART_HOME}: ${fs:-нет}."
                    return 1
                    ;;
            esac
        fi
    else
        CFG_FORMAT_HOME=no
        CFG_HOME_MODE=no
    fi
    return 0
}

disks_manual_validate() {
    [[ -b $CFG_PART_ROOT ]] || {
        ui_error "Нет root" "Корневой раздел не найден."
        return 1
    }
    if [[ $CFG_BOOT_MODE == uefi ]]; then
        [[ -b $CFG_PART_ESP ]] || {
            ui_error "Нет ESP" "EFI System Partition не найдена."
            return 1
        }
    else
        [[ -b $CFG_PART_BOOT ]] || {
            ui_error "Нет /boot" "Раздел /boot не найден."
            return 1
        }
    fi
    [[ -n $CFG_PART_SWAP && ! -b $CFG_PART_SWAP ]] && {
        ui_error "Нет swap" "Раздел swap не найден."
        return 1
    }
    [[ -n $CFG_PART_HOME && ! -b $CFG_PART_HOME ]] && {
        ui_error "Нет /home" "Раздел /home не найден."
        return 1
    }
    return 0
}

disks_format_manual() {
    if [[ $CFG_FORMAT_ESP == yes && -n $CFG_PART_ESP ]]; then
        disk_format_fs vfat "$CFG_PART_ESP" EFI || return 1
    fi
    if [[ $CFG_FORMAT_BOOT == yes && -n $CFG_PART_BOOT ]]; then
        disk_format_fs "$CFG_BOOT_FS" "$CFG_PART_BOOT" boot || return 1
    fi
    if [[ $CFG_FORMAT_SWAP == yes && -n $CFG_PART_SWAP ]]; then
        disk_format_fs swap "$CFG_PART_SWAP" swap || return 1
    fi
    if [[ $CFG_FORMAT_ROOT == yes ]]; then
        disk_format_fs "$CFG_ROOT_FS" "$CFG_PART_ROOT" root || return 1
    fi
    if [[ -n $CFG_PART_HOME && $CFG_FORMAT_HOME == yes ]]; then
        disk_format_fs "$CFG_HOME_FS" "$CFG_PART_HOME" home || return 1
    fi
}

disk_partition_manual() {
    if [[ -z $CFG_DISK || ! -b $CFG_DISK || -z $CFG_PART_ROOT || ! -b $CFG_PART_ROOT ]]; then
        disks_manual_assign || return 1
    fi
    disks_check_target || return 1
    disks_manual_options || return 1
    disks_manual_validate || return 1

    ui_header "Проверка ручной схемы" "Будут отформатированы выбранные разделы"
    ui_wrap "root: ${CFG_PART_ROOT} (${CFG_ROOT_FS})
ESP: ${CFG_PART_ESP:-—}
/boot: ${CFG_PART_BOOT:-—}
swap: ${CFG_PART_SWAP:-—}
/home: ${CFG_PART_HOME:-—}

Изменения уничтожат данные на форматируемых разделах."
    ui_footer "Enter — подтвердить · Esc — отмена"
    ui_read_key || return 1
    [[ $UI_KEY != esc ]] || return 1
    if ((!GI_ASSUME_YES)); then
        ui_input "Подтверждение" "Введите ERASE для форматирования выбранных разделов:" \
            "" disks_validate_erase "Данные на выбранных разделах будут уничтожены" no || return 1
    fi
    disks_format_manual || return 1
    disks_capture_uuids || return 1
    config_save
    disks_mount_all || return 1
}

# ---------------------------------------------------------------------------
# UUIDs and mounting
# ---------------------------------------------------------------------------

disks_capture_uuids() {
    local uuid
    if [[ -n $CFG_PART_ESP ]]; then
        uuid=$(fs_uuid "$CFG_PART_ESP")
        [[ -n $uuid ]] || die "не удалось получить UUID для ESP ${CFG_PART_ESP}"
        CFG_UUID_ESP=$uuid
    fi
    if [[ -n $CFG_PART_BOOT ]]; then
        uuid=$(fs_uuid "$CFG_PART_BOOT")
        [[ -n $uuid ]] || die "не удалось получить UUID для /boot ${CFG_PART_BOOT}"
        CFG_UUID_BOOT=$uuid
    fi
    if [[ -n $CFG_PART_SWAP ]]; then
        uuid=$(fs_uuid "$CFG_PART_SWAP")
        [[ -n $uuid ]] || die "не удалось получить UUID для swap ${CFG_PART_SWAP}"
        CFG_UUID_SWAP=$uuid
    fi
    uuid=$(fs_uuid "$CFG_PART_ROOT")
    [[ -n $uuid ]] || die "не удалось получить UUID для root ${CFG_PART_ROOT}"
    CFG_UUID_ROOT=$uuid
    if [[ -n $CFG_PART_HOME ]]; then
        uuid=$(fs_uuid "$CFG_PART_HOME")
        [[ -n $uuid ]] || die "не удалось получить UUID для /home ${CFG_PART_HOME}"
        CFG_UUID_HOME=$uuid
    else
        CFG_UUID_HOME=""
    fi
}

mount_by_uuid() {
    local uuid=$1 target=$2 fstype=$3
    local current
    if is_mounted "$target"; then
        current=$(findmnt -n -o SOURCE --mountpoint "$target" 2>/dev/null || true)
        if [[ $(fs_uuid "$current") == "$uuid" ]]; then
            return 0
        fi
        ui_error "Точка занята" "${target} уже содержит другую файловую систему (${current})."
        return 1
    fi
    ensure_dir "$target"
    if [[ $fstype == vfat ]]; then
        ui_run "Монтирование ${target}" mount -o umask=0077 "UUID=${uuid}" "$target" || return 1
    else
        ui_run "Монтирование ${target}" mount "UUID=${uuid}" "$target" || return 1
    fi
}

disks_mount_all() {
    local target
    if ! is_mounted "$GI_ROOT"; then
        ensure_dir "$GI_ROOT"
        [[ -n $CFG_UUID_ROOT ]] || die "UUID root не определён"
        mount_by_uuid "$CFG_UUID_ROOT" "$GI_ROOT" "root" || return 1
    else
        target=$(mount_source_for "$GI_ROOT")
        if [[ -n $CFG_UUID_ROOT && $(fs_uuid "$target") != "$CFG_UUID_ROOT" ]]; then
            ui_error "Неверный root" "${GI_ROOT} уже занят ${target}."
            return 1
        fi
    fi

    if [[ $CFG_BOOT_MODE == uefi ]]; then
        if [[ -z $CFG_UUID_ESP ]]; then
            die "UUID ESP не определён"
        fi
        ensure_dir "$GI_ROOT/efi"
        mount_by_uuid "$CFG_UUID_ESP" "$GI_ROOT/efi" vfat || return 1
    else
        if [[ -z $CFG_UUID_BOOT ]]; then
            die "UUID /boot не определён"
        fi
        ensure_dir "$GI_ROOT/boot"
        mount_by_uuid "$CFG_UUID_BOOT" "$GI_ROOT/boot" "boot" || return 1
    fi

    if [[ -n $CFG_PART_HOME && -n $CFG_UUID_HOME ]]; then
        ensure_dir "$GI_ROOT/home"
        mount_by_uuid "$CFG_UUID_HOME" "$GI_ROOT/home" "home" || return 1
    fi

    if [[ -n $CFG_PART_SWAP && -n $CFG_UUID_SWAP ]]; then
        if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$CFG_PART_SWAP"; then
            ui_run "Активация swap" swapon "UUID=${CFG_UUID_SWAP}" || return 1
        fi
    fi

    local avail
    avail=$(free_space_mib "$GI_ROOT")
    if [[ -n $avail ]] && ((avail < 6144)); then
        ui_error "Мало места" "На корневом разделе доступно ${avail} MiB. Нужно минимум 6 GiB."
        return 1
    fi
    log_info "root mounted: $(mount_source_for "$GI_ROOT"), available ${avail} MiB"
}

disks_unmount_all() {
    local status=0 swap_target=""
    if [[ -n $CFG_UUID_SWAP ]]; then
        swap_target="UUID=${CFG_UUID_SWAP}"
    elif [[ -n $CFG_PART_SWAP ]]; then
        swap_target=$CFG_PART_SWAP
    fi
    if [[ -n $swap_target ]]; then
        swapoff "$swap_target" 2>/dev/null || true
    fi
    if is_mounted "$GI_ROOT"; then
        umount -R -- "$GI_ROOT" || status=$?
    fi
    return "$status"
}

# ---------------------------------------------------------------------------
# Installation step
# ---------------------------------------------------------------------------

step_disk() {
    if is_mounted "$GI_ROOT"; then
        ui_msg "Повторная разметка" "Целевая система уже смонтирована. Установщик размонтирует её перед повторной разметкой."
        chroot_unmount
        disks_unmount_all || return 1
    fi
    if [[ -n $CFG_PART_SWAP ]]; then
        swapoff "$CFG_PART_SWAP" 2>/dev/null || true
    fi
    if [[ $CFG_DISK_MODE == auto ]]; then
        if [[ -z $CFG_DISK ]]; then
            disks_select_disk || return 1
        fi
        if ! disks_check_target; then
            return 1
        fi
        local disk_mib
        disk_mib=$(disk_size_mib "$CFG_DISK") || return 1
        disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" || {
            ui_error "План разметки" "$PLAN_ERROR"
            return 1
        }
        ui_header "План разметки" "Проверьте размеры и точки монтирования"
        ui_wrap "$(disk_plan_print)"
        ui_pause "Enter — перейти к подтверждению"
        disk_partition_auto || return 1
    else
        disk_partition_manual || return 1
    fi
    config_derived
    config_save
    log_info "disk step finished"
}
