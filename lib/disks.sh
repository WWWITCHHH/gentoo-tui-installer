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

# Prints the size of a block device in bytes. KVM/QEMU virtio disks and some
# minimal live environments return an empty or zero result from blockdev, so
# use lsblk and sysfs as validated fallbacks instead of treating that as 0 MiB.
disk_size_bytes() {
    local disk=$1 name bytes="" sectors="" path
    name=${disk##*/}

    if command_exists blockdev; then
        bytes=$(blockdev --getsize64 -- "$disk" 2>/dev/null || true)
        bytes=${bytes//[[:space:]]/}
    fi
    if [[ ! $bytes =~ ^[0-9]+$ ]] || ((bytes <= 0)); then
        bytes=$(lsblk -bndo SIZE -- "$disk" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
    fi
    if [[ ! $bytes =~ ^[0-9]+$ ]] || ((bytes <= 0)); then
        for path in "${GI_SYS_BLOCK:-/sys/block}/${name}/size" \
            "${GI_SYS_CLASS_BLOCK:-/sys/class/block}/${name}/size"; do
            [[ -r $path ]] || continue
            sectors=$(<"$path")
            sectors=${sectors//[[:space:]]/}
            if [[ $sectors =~ ^[0-9]+$ ]] && ((sectors > 0)); then
                bytes=$((sectors * 512))
                break
            fi
        done
    fi
    if [[ ! $bytes =~ ^[0-9]+$ ]] || ((bytes <= 0)); then
        return 1
    fi
    printf '%s\n' "$bytes"
}

disk_size_mib() {
    local disk=$1 bytes mib
    bytes=$(disk_size_bytes "$disk") || return 1
    mib=$((bytes / 1024 / 1024))
    # A device smaller than 1 MiB is never a usable installation target.
    ((mib > 0)) || return 1
    printf '%d' "$mib"
}

disk_model() {
    local model
    model=$(lsblk -dno MODEL -- "$1" 2>/dev/null || true)
    trim "${model:-unknown}"
}

disk_is_removable() {
    local name=${1##*/} value=0 path
    path="${GI_SYS_BLOCK:-/sys/block}/${name}/removable"
    [[ -r $path ]] || path="${GI_SYS_CLASS_BLOCK:-/sys/class/block}/${name}/removable"
    [[ -r $path ]] && read -r value <"$path" || true
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
        PLAN_ERROR="$(T 'Partition size for %s must be greater than zero.' "$role")"
        return 1
    fi
    if ((PLAN_COUNT == 0)); then
        start=1
    else
        start=${PLAN_END[PLAN_COUNT - 1]}
    fi
    end=$((start + size))
    if ((end > PLAN_TOTAL_MIB - 1)); then
        PLAN_ERROR="$(T 'Partition %s does not fit on the disk.' "$role")"
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
    if ((disk_mib <= 0)); then
        PLAN_ERROR="$(T 'unable to determine disk size')"
        return 1
    fi
    if ((disk_mib < 4096)); then
        PLAN_ERROR="$(T 'Disk is too small (%s MiB).' "$disk_mib")"
        return 1
    fi
    if [[ $boot_mode == bios ]] && ((disk_mib > 2097152)); then
        PLAN_ERROR="$(T 'BIOS + MBR does not support disks larger than 2 TiB.')"
        return 1
    fi

    case "$CFG_SWAP_MODE" in
        auto) swap_mib=$(suggest_swap_mib) ;;
        none) swap_mib=0 ;;
        custom) swap_mib=${CFG_SWAP_MIB:-0} ;;
        *) PLAN_ERROR="$(T 'unknown swap mode')"; return 1 ;;
    esac
    if [[ $CFG_HOME_MODE == separate ]]; then
        home_mib=${CFG_HOME_MIB:-0}
        if ((home_mib <= 0)); then
            PLAN_ERROR="$(T '/home size must be greater than zero.')"
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
        PLAN_ERROR="$(T 'unknown boot mode')"
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
            PLAN_ERROR="$(T 'Root would be smaller than %s MiB; reduce swap or /home.' "$min_root")"
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
            PLAN_ERROR="$(T 'Root would be smaller than %s MiB; reduce swap.' "$min_root")"
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
    printf '%s\n' "$(T 'Scheme: %s' "$([[ $CFG_BOOT_MODE == uefi ]] && printf 'UEFI + GPT' || printf 'BIOS + MBR')")"
    printf '%s\n' "$(T 'Disk:  %s (%s, %s)' "$CFG_DISK" "$(disk_model "$CFG_DISK")" "$(human_mib "$PLAN_TOTAL_MIB")")"
    printf '\n'
    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        printf '  %-12s %-8s %-7s %-6s %s\n' \
            "$path" "${PLAN_LABEL[$i]}" "${PLAN_FSTYPE[$i]}" \
            "$(human_mib "${PLAN_SIZE[$i]}")" "${PLAN_MOUNT[$i]/none/—}"
    done
    printf '\n'
    printf '%s\n' "$(T 'Changes will destroy ALL data on %s.' "$CFG_DISK")"
}

disk_plan_markdown() {
    local i path
    printf '## %s\n\n' "$(T 'Partition plan')"
    printf '| %s | %s | %s | %s | %s |\n' "$(T 'Partition')" "$(T 'Role')" "$(T 'FS')" "$(T 'Size')" "$(T 'Mount point')"
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
    local disk size size_mib size_note model transport removable label default=""
    mapfile -t entries < <(discover_disks)
    ((${#entries[@]} > 0)) || return 1
    for disk in "${entries[@]}"; do
        if size_mib=$(disk_size_mib "$disk" 2>/dev/null); then
            size_note=$(human_mib "$size_mib")
        else
            size_note=$(T 'size unknown')
            size_mib=0
        fi
        size=$(lsblk -dno SIZE -- "$disk" 2>/dev/null | xargs || true)
        size=${size:-$size_note}
        model=$(disk_model "$disk")
        transport=$(lsblk -dno TRAN -- "$disk" 2>/dev/null | xargs || true)
        removable=""
        disk_is_removable "$disk" && removable=" · $(T 'removable')"
        label="${disk} — ${size} · ${model}${transport:+ · $transport}${removable}"
        tags+=("$disk")
        labels+=("${disk}|${label}|${size_note}")
        [[ $disk == "$CFG_DISK" ]] && default=$disk
    done
    [[ -z $default ]] && default=${tags[0]}
    if ui_menu "$(T 'Target disk')" \
        "$(T 'All partitions and signatures on the selected disk will be destroyed')" \
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
        ui_error "$(T 'Invalid disk')" "$VALIDATION_MESSAGE"
        return 1
    fi
    if disks_disk_mounted; then
        ui_error "$(T 'Disk is already in use')" \
            "$(T 'Mounted partitions exist on %s. Unmount them before installing.' "$CFG_DISK")"
        return 1
    fi
    local swaps
    swaps=$(lsblk -nrno NAME -- "$CFG_DISK" 2>/dev/null | while read -r name; do
        grep -q "^/dev/${name}[[:space:]]" /proc/swaps 2>/dev/null && printf '%s\n' "$name"
    done)
    if [[ -n $swaps ]]; then
        ui_error "$(T 'Active swap')" "$(T 'Disable swap on %s: swapoff -a' "$CFG_DISK")"
        return 1
    fi
    return 0
}

disks_validate_erase() {
    [[ $1 == ERASE ]] && return 0
    VALIDATION_MESSAGE="$(T 'Type ERASE in uppercase to confirm.')"
    return 1
}

disks_confirm_destruction() {
    local plan
    if ((GI_ASSUME_YES)); then
        log_warn "destructive confirmation skipped (--yes)"
        return 0
    fi
    plan=$(disk_plan_print)
    ui_header "$(T 'Final warning')" "$(T 'Data on the disk will be destroyed permanently')"
    ui_wrap "$plan"
    printf '\n'
    ui_input "$(T 'Confirmation')" "$(T 'Type ERASE to start partitioning and formatting:')" \
        "" disks_validate_erase "$(T 'This action cannot be undone')" no
}

disk_format_fs() {
    local fstype=$1 device=$2 label=$3
    ui_run "$(T 'Wiping signatures: %s' "$device")" wipefs -a "$device" || return 1
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
            die "$(T 'unknown filesystem: %s' "$fstype")"
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
    ui_run "$(T 'Creating %s partition table' "${label_type^^}")" "${cmd[@]}" || return 1

    for ((i = 0; i < PLAN_COUNT; i++)); do
        path=$(plan_partition_path "$i")
        role=${PLAN_ROLE[$i]}
        fstype=${PLAN_FSTYPE[$i]}
        part_type=$(parted_fs_type "$fstype")
        if [[ $CFG_BOOT_MODE == uefi ]]; then
            ui_run "$(T 'Partition %s: %s' "$path" "$role")" parted --script --align optimal "$CFG_DISK" \
                mkpart "${PLAN_LABEL[$i]}" "$part_type" "${PLAN_START[$i]}MiB" "${PLAN_END[$i]}MiB" || return 1
            if [[ $role == esp ]]; then
                ui_run "$(T 'ESP flag')" parted --script "$CFG_DISK" set "${PLAN_NUM[$i]}" esp on || return 1
            fi
        else
            ui_run "$(T 'Partition %s: %s' "$path" "$role")" parted --script --align optimal "$CFG_DISK" \
                mkpart primary "$part_type" "${PLAN_START[$i]}MiB" "${PLAN_END[$i]}MiB" || return 1
        fi
    done
    if [[ $CFG_BOOT_MODE == bios ]]; then
        ui_run "$(T 'boot flag')" parted --script "$CFG_DISK" set 1 boot on || return 1
    fi
    ui_run "$(T 'Reloading the partition table')" partprobe "$CFG_DISK" || return 1
    ui_run "$(T 'Waiting for udev')" udevadm settle || true
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
            die "$(T 'the kernel did not detect the created partition %s' "$path")"
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
    disk_mib=$(disk_size_mib "$CFG_DISK") || die "$(T 'unable to determine the size of %s' "$CFG_DISK")"
    disk_plan_build "$CFG_BOOT_MODE" "$disk_mib" || die "$(T 'partition plan: %s' "$PLAN_ERROR")"
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
        label="${name} — ${size} — ${fstype:-$(T 'no filesystem')}"
        [[ -n $mountpoints ]] && label+=" — ${mountpoints}"
        printf '%s|%s|\n' "$name" "$label"
    done < <(lsblk -Ppno NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS -- "$CFG_DISK" 2>/dev/null)
}

disks_choose_fs() {
    local title=$1 default=$2
    ui_menu "$title" "$(T 'The filesystem will be created from scratch')" "$default" \
        "xfs|XFS|$(T 'Reliable default filesystem, recommended for Gentoo')" \
        "ext4|ext4|$(T 'Classic and predictable filesystem')" \
        "btrfs|Btrfs|$(T 'Snapshots and compression; subvolumes are not configured')" || return 1
}

disks_choose_partition() {
    local title=$1 role=$2 allow_none=${3:-no}
    local -a items=() entries=()
    local default var used
    while :; do
        mapfile -t entries < <(disks_partition_menu_items)
        if ((${#entries[@]} == 0)); then
            ui_error "$(T 'No partitions found')" "$(T 'Create partitions on %s and try again.' "$CFG_DISK")"
            return 1
        fi
        items=("${entries[@]}")
        if [[ $allow_none == yes ]]; then
            items+=("none|$(T 'Do not use')|$(T 'No separate partition')")
        fi
        default=${!role}
        if [[ -z $default ]]; then
            if [[ $allow_none == yes ]]; then
                default=none
            else
                default=${items[0]%%|*}
            fi
        fi
        ui_menu "$title" "$(T 'Choose a partition for the %s role' "$role")" "$default" "${items[@]}" || return 1
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
            ui_error "$(T 'Partition already in use')" "$(T 'One partition cannot be assigned to two roles.')"
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
        if ui_confirm "$(T 'Manual partitioning')" \
            "$(T 'Open cfdisk for %s?\n\nCreate the partitions first. After exiting, assign them to roles.\nUEFI: an ESP (vfat) is required. BIOS: /boot (ext4/xfs/btrfs) is required.' "$CFG_DISK")" no; then
            ui_interactive "$(T 'cfdisk %s' "$CFG_DISK")" cfdisk "$CFG_DISK" || return 1
            ui_run "$(T 'Reloading the partition table')" partprobe "$CFG_DISK" || true
            ui_run "$(T 'Waiting for udev')" udevadm settle || true
        fi
    fi

    CFG_PART_ESP="" CFG_PART_BOOT="" CFG_PART_SWAP="" CFG_PART_ROOT="" CFG_PART_HOME=""
    disks_choose_partition "$(T 'Root partition')" CFG_PART_ROOT no || return 1
    if [[ $CFG_BOOT_MODE == uefi ]]; then
        disks_choose_partition "$(T 'EFI System Partition')" CFG_PART_ESP no || return 1
    else
        disks_choose_partition "$(T '/boot partition')" CFG_PART_BOOT no || return 1
    fi
    local result=0
    disks_choose_partition "$(T 'Swap (optional)')" CFG_PART_SWAP yes || result=$?
    if ((result == 1)); then
        return 1
    fi
    CFG_HOME_MODE=no
    if ui_confirm "$(T 'Separate /home')" "$(T 'Create a separate /home partition?')" no; then
        disks_choose_partition "$(T '/home partition')" CFG_PART_HOME no || return 1
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
            ui_error "$(T 'Different disks')" "$(T 'All selected partitions must be on the same disk.')"
            return 1
        fi
    done
    if [[ -z $disk_name ]]; then
        ui_error "$(T 'Could not determine the disk')" "$(T 'The partitions are not associated with a whole disk.')"
        return 1
    fi
    CFG_DISK="/dev/${disk_name#/dev/}"

    local ptt
    ptt=$(lsblk -dno PTTYPE -- "$CFG_DISK" 2>/dev/null | xargs)
    if [[ $CFG_BOOT_MODE == uefi && $ptt != gpt ]]; then
        ui_error "$(T 'GPT required')" "$(T 'The UEFI layout requires GPT (found: %s).' "${ptt:-$(T 'none')}")"
        return 1
    fi
    if [[ $CFG_BOOT_MODE == bios && $ptt != dos ]]; then
        ui_error "$(T 'MBR required')" "$(T 'The BIOS layout requires MBR/DOS (found: %s).' "${ptt:-$(T 'none')}")"
        return 1
    fi
    return 0
}

disks_manual_options() {
    local fs
    ui_header "$(T 'Partitions and filesystems')" "$(T 'Formatting destroys data on the selected partitions')"
    ui_wrap "root: ${CFG_PART_ROOT}
ESP: ${CFG_PART_ESP:-—}
/boot: ${CFG_PART_BOOT:-—}
swap: ${CFG_PART_SWAP:-—}
/home: ${CFG_PART_HOME:-—}"
    printf '\n'

    if ! disks_choose_fs "$(T 'Root filesystem')" "$CFG_ROOT_FS"; then
        return 1
    fi
    CFG_ROOT_FS=$UI_RESULT
    CFG_FORMAT_ROOT=yes

    if [[ $CFG_BOOT_MODE == uefi ]]; then
        if ui_confirm "$(T 'Format the ESP?')" \
            "$(T 'Reformat %s as FAT32? For dual boot the answer is usually NO.' "$CFG_PART_ESP")" no; then
            CFG_FORMAT_ESP=yes
        else
            CFG_FORMAT_ESP=no
            fs=$(fs_type "$CFG_PART_ESP")
            if [[ $fs != vfat ]]; then
                ui_error "$(T 'ESP is not vfat')" "$(T 'Partition %s must contain FAT32 (found: %s).' "$CFG_PART_ESP" "${fs:-$(T 'none')}")"
                return 1
            fi
        fi
    else
        if ui_confirm "$(T 'Format /boot?')" "$(T 'Reformat %s?' "$CFG_PART_BOOT")" yes; then
            CFG_FORMAT_BOOT=yes
            if ! disks_choose_fs "$(T '/boot filesystem')" "$CFG_BOOT_FS"; then
                return 1
            fi
            CFG_BOOT_FS=$UI_RESULT
        else
            CFG_FORMAT_BOOT=no
            fs=$(fs_type "$CFG_PART_BOOT")
            case "$fs" in
                ext4|xfs|btrfs) CFG_BOOT_FS=$fs ;;
                *)
                    ui_error "$(T 'Invalid /boot')" "$(T 'Filesystem on %s: %s.' "$CFG_PART_BOOT" "${fs:-$(T 'none')}")"
                    return 1
                    ;;
            esac
        fi
    fi

    if [[ -n $CFG_PART_SWAP ]]; then
        if ui_confirm "$(T 'Format swap?')" "$(T 'Run mkswap on %s?' "$CFG_PART_SWAP")" yes; then
            CFG_FORMAT_SWAP=yes
            CFG_SWAP_MODE=custom
            CFG_SWAP_MIB=$(disk_size_mib "$CFG_PART_SWAP" 2>/dev/null || printf '0')
        else
            CFG_FORMAT_SWAP=no
            fs=$(fs_type "$CFG_PART_SWAP")
            if [[ $fs != swap ]]; then
                ui_error "$(T 'Not swap')" "$(T 'Partition %s does not contain a swap signature (found: %s).' "$CFG_PART_SWAP" "${fs:-$(T 'none')}")"
                return 1
            fi
            CFG_SWAP_MODE=custom
            CFG_SWAP_MIB=$(disk_size_mib "$CFG_PART_SWAP" 2>/dev/null || printf '0')
        fi
    else
        CFG_FORMAT_SWAP=no
        CFG_SWAP_MODE=none
        CFG_SWAP_MIB=0
    fi

    if [[ -n $CFG_PART_HOME ]]; then
        CFG_HOME_MODE=separate
        if ui_confirm "$(T 'Format /home?')" "$(T 'Formatting %s will destroy its data.' "$CFG_PART_HOME")" no; then
            CFG_FORMAT_HOME=yes
            if ! disks_choose_fs "$(T '/home filesystem')" "$CFG_HOME_FS"; then
                return 1
            fi
            CFG_HOME_FS=$UI_RESULT
        else
            CFG_FORMAT_HOME=no
            fs=$(fs_type "$CFG_PART_HOME")
            case "$fs" in
                ext4|xfs|btrfs) CFG_HOME_FS=$fs ;;
                *)
                    ui_error "$(T 'Invalid /home')" "$(T 'Filesystem on %s: %s.' "$CFG_PART_HOME" "${fs:-$(T 'none')}")"
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
        ui_error "$(T 'No root partition')" "$(T 'The root partition was not found.')"
        return 1
    }
    if [[ $CFG_BOOT_MODE == uefi ]]; then
        [[ -b $CFG_PART_ESP ]] || {
            ui_error "$(T 'No ESP')" "$(T 'The EFI System Partition was not found.')"
            return 1
        }
    else
        [[ -b $CFG_PART_BOOT ]] || {
            ui_error "$(T 'No /boot partition')" "$(T 'The /boot partition was not found.')"
            return 1
        }
    fi
    [[ -n $CFG_PART_SWAP && ! -b $CFG_PART_SWAP ]] && {
        ui_error "$(T 'No swap partition')" "$(T 'The swap partition was not found.')"
        return 1
    }
    [[ -n $CFG_PART_HOME && ! -b $CFG_PART_HOME ]] && {
        ui_error "$(T 'No /home partition')" "$(T 'The /home partition was not found.')"
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

    ui_header "$(T 'Check the manual layout')" "$(T 'The selected partitions will be formatted')"
    ui_wrap "root: ${CFG_PART_ROOT} (${CFG_ROOT_FS})
ESP: ${CFG_PART_ESP:-—}
/boot: ${CFG_PART_BOOT:-—}
swap: ${CFG_PART_SWAP:-—}
/home: ${CFG_PART_HOME:-—}

$(T 'The changes will destroy data on the partitions being formatted.')"
    ui_footer "$(T 'Enter - confirm · Esc - cancel')"
    ui_read_key || return 1
    [[ $UI_KEY != esc ]] || return 1
    if ((!GI_ASSUME_YES)); then
        ui_input "$(T 'Confirmation')" "$(T 'Type ERASE to format the selected partitions:')" \
            "" disks_validate_erase "$(T 'Data on the selected partitions will be destroyed')" no || return 1
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
        [[ -n $uuid ]] || die "$(T 'failed to read the UUID of ESP %s' "$CFG_PART_ESP")"
        CFG_UUID_ESP=$uuid
    fi
    if [[ -n $CFG_PART_BOOT ]]; then
        uuid=$(fs_uuid "$CFG_PART_BOOT")
        [[ -n $uuid ]] || die "$(T 'failed to read the UUID of /boot %s' "$CFG_PART_BOOT")"
        CFG_UUID_BOOT=$uuid
    fi
    if [[ -n $CFG_PART_SWAP ]]; then
        uuid=$(fs_uuid "$CFG_PART_SWAP")
        [[ -n $uuid ]] || die "$(T 'failed to read the UUID of swap %s' "$CFG_PART_SWAP")"
        CFG_UUID_SWAP=$uuid
    fi
    uuid=$(fs_uuid "$CFG_PART_ROOT")
    [[ -n $uuid ]] || die "$(T 'failed to read the UUID of root %s' "$CFG_PART_ROOT")"
    CFG_UUID_ROOT=$uuid
    if [[ -n $CFG_PART_HOME ]]; then
        uuid=$(fs_uuid "$CFG_PART_HOME")
        [[ -n $uuid ]] || die "$(T 'failed to read the UUID of /home %s' "$CFG_PART_HOME")"
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
        ui_error "$(T 'Mount point busy')" "$(T '%s already contains a different filesystem (%s).' "$target" "$current")"
        return 1
    fi
    ensure_dir "$target"
    if [[ $fstype == vfat ]]; then
        ui_run "$(T 'Mounting %s' "$target")" mount -o umask=0077 "UUID=${uuid}" "$target" || return 1
    else
        ui_run "$(T 'Mounting %s' "$target")" mount "UUID=${uuid}" "$target" || return 1
    fi
}

disks_mount_all() {
    local target
    if ! is_mounted "$GI_ROOT"; then
        ensure_dir "$GI_ROOT"
        [[ -n $CFG_UUID_ROOT ]] || die "$(T 'root UUID is not set')"
        mount_by_uuid "$CFG_UUID_ROOT" "$GI_ROOT" "root" || return 1
    else
        target=$(mount_source_for "$GI_ROOT")
        if [[ -n $CFG_UUID_ROOT && $(fs_uuid "$target") != "$CFG_UUID_ROOT" ]]; then
            ui_error "$(T 'Wrong root')" "$(T '%s is already occupied by %s.' "$GI_ROOT" "$target")"
            return 1
        fi
    fi

    if [[ $CFG_BOOT_MODE == uefi ]]; then
        if [[ -z $CFG_UUID_ESP ]]; then
            die "$(T 'ESP UUID is not set')"
        fi
        ensure_dir "$GI_ROOT/efi"
        mount_by_uuid "$CFG_UUID_ESP" "$GI_ROOT/efi" vfat || return 1
    else
        if [[ -z $CFG_UUID_BOOT ]]; then
            die "$(T '/boot UUID is not set')"
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
            ui_run "$(T 'Activating swap')" swapon "UUID=${CFG_UUID_SWAP}" || return 1
        fi
    fi

    local avail
    avail=$(free_space_mib "$GI_ROOT")
    if [[ -n $avail ]] && ((avail < 6144)); then
        ui_error "$(T 'Not enough space')" "$(T 'Only %s MiB are available on the root partition. At least 6 GiB are required.' "$avail")"
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
        ui_msg "$(T 'Repartitioning')" "$(T 'The target system is already mounted. The installer will unmount it before repartitioning.')"
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
            ui_error "$(T 'Partition plan')" "$PLAN_ERROR"
            return 1
        }
        ui_header "$(T 'Partition plan')" "$(T 'Check the sizes and mount points')"
        ui_wrap "$(disk_plan_print)"
        ui_pause "$(T 'Enter - continue to confirmation')"
        disk_partition_auto || return 1
    else
        disk_partition_manual || return 1
    fi
    config_derived
    config_save
    log_info "disk step finished"
}
