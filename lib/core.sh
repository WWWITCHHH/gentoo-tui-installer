# shellcheck shell=bash
# Core state, logging, configuration and small common helpers.

GI_NAME="gentoo-tui-installer"
if [[ -z ${GI_VERSION:-} ]]; then
    GI_VERSION=dev
fi
GI_ROOT="${GI_ROOT:-/mnt/gentoo}"
GI_WORKDIR="${GI_WORKDIR:-/var/lib/gentoo-installer}"
GI_CONFIG_FILE="${GI_WORKDIR}/install.conf"
GI_STATE_FILE="${GI_WORKDIR}/state"
GI_LOG_DIR="${GI_WORKDIR}/logs"
GI_LOG_FILE="${GI_LOG_DIR}/install.log"
GI_DOWNLOAD_DIR="${GI_WORKDIR}/downloads"
GI_GNUPG_HOME="${GI_WORKDIR}/gnupg"

GI_UI_ACTIVE=0
GI_ABORTED=0
GI_CURRENT_STEP=""
GI_STEP_INDEX=0
GI_STEP_TOTAL=9
GI_RUN_COUNTER=0
GI_LAST_LOG=""
GI_LAST_COMMAND=""
GI_DEBUG=0
GI_RESUME=0
GI_ASSUME_YES=0

CONFIG_KEYS=(
    SCHEMA
    BOOT_MODE DISK_MODE DISK ROOT_FS HOME_FS SWAP_MODE SWAP_MIB HOME_MODE HOME_MIB
    PART_ESP PART_BOOT PART_SWAP PART_ROOT PART_HOME
    FORMAT_ESP FORMAT_BOOT FORMAT_SWAP FORMAT_ROOT FORMAT_HOME
    UUID_ESP UUID_BOOT UUID_SWAP UUID_ROOT UUID_HOME BOOT_FS
    STAGE_FLAVOR MIRROR STAGE_URL PROFILE DESKTOP CPU_FLAGS UPDATE_WORLD MAKE_JOBS
    CFLAGS VIDEO_CARDS USE_EXTRA
    KERNEL_MODE FIRMWARE MICROCODE KERNEL_CMDLINE BOOTLOADER
    HOSTNAME TIMEZONE LOCALE KEYMAP HWCLOCK NETWORK SSH CRON CHRONY SYSLOG
    SUDO USERNAME CREATE_USER
)

STATE_STEPS=(disk stage3 portage kernel system tools bootloader desktop finalize)
declare -A STATE_DONE=()
VALIDATION_ERRORS=()
UI_RESULT=""
UI_SECRET=""
UI_CANCELLED=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_init() {
    mkdir -p -- "$GI_LOG_DIR" "$GI_DOWNLOAD_DIR" "$GI_GNUPG_HOME"
    chmod 0700 -- "$GI_WORKDIR" "$GI_LOG_DIR" "$GI_GNUPG_HOME"
    touch -- "$GI_LOG_FILE"
    chmod 0600 -- "$GI_LOG_FILE"
    log_msg INFO "=== ${GI_NAME} ${GI_VERSION} started $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
}

log_msg() {
    local level=$1
    shift
    local line
    line=$(printf '%s [%-5s] %s' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$level" "$*")
    if [[ -n ${GI_LOG_FILE:-} ]]; then
        printf '%s\n' "$line" >>"$GI_LOG_FILE" 2>/dev/null || true
    fi
    if ((GI_DEBUG)); then
        printf '%s\n' "$line" >&2
    fi
}

log_info() { log_msg INFO "$@"; }
log_warn() { log_msg WARN "$@"; }
log_error() { log_msg ERROR "$@"; }

die() {
    local message=$*
    log_error "$message"
    if command -v ui_cleanup >/dev/null 2>&1; then
        ui_cleanup || true
    fi
    printf '\nОшибка: %s\n' "$message" >&2
    if [[ -n ${GI_LOG_FILE:-} && -f ${GI_LOG_FILE:-} ]]; then
        printf 'Журнал: %s\n' "$GI_LOG_FILE" >&2
    fi
    exit 1
}

warn() {
    log_warn "$*"
    printf 'Внимание: %s\n' "$*" >&2
}

info() {
    log_info "$*"
    printf '%s\n' "$*"
}

# ---------------------------------------------------------------------------
# Command rendering and small helpers
# ---------------------------------------------------------------------------

render_cmd() {
    local arg q out=""
    for arg in "$@"; do
        printf -v q '%q' "$arg"
        out+=" ${q}"
    done
    printf '%s' "${out# }"
}

run_logged() {
    local log=$1
    shift
    log_info "CMD: $(render_cmd "$@")"
    printf '\n$ %s\n' "$(render_cmd "$@")" >>"$log"
    "$@" >>"$log" 2>&1
}

is_yes() {
    case "${1:-}" in
        yes|YES|y|Y|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

human_mib() {
    local mib=${1:-0}
    if ((mib >= 1024 * 1024)); then
        printf '%d TiB' "$((mib / 1024 / 1024))"
    elif ((mib >= 1024)); then
        printf '%d GiB' "$((mib / 1024))"
    else
        printf '%d MiB' "$mib"
    fi
}

# Quotes a value for safe inclusion in a shell configuration file.
shell_quote() {
    local value=$1
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

ensure_dir() {
    [[ -d $1 ]] || mkdir -p -- "$1"
}

free_space_mib() {
    df -Pm --output=avail -- "$1" 2>/dev/null | awk 'NR==2 {print $1; exit}'
}

path_exists() {
    [[ -e $1 || -L $1 ]]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

write_file_atomic() {
    local path=$1 mode=${2:-0644}
    local tmp
    tmp=$(mktemp "${path}.tmp.XXXXXX")
    cat >"$tmp"
    chmod -- "$mode" "$tmp"
    mv -f -- "$tmp" "$path"
}

part_path() {
    local disk=$1 num=$2
    if [[ ${disk##*/} =~ [0-9]$ ]]; then
        printf '%sp%s' "$disk" "$num"
    else
        printf '%s%s' "$disk" "$num"
    fi
}

fs_uuid() {
    blkid -s UUID -o value -- "$1" 2>/dev/null || true
}

fs_type() {
    blkid -s TYPE -o value -- "$1" 2>/dev/null || true
}

mount_source_for() {
    findmnt -n -o SOURCE --target "$1" 2>/dev/null || true
}

is_mounted() {
    mountpoint -q -- "$1" 2>/dev/null
}

require_mountpoint() {
    local path=$1
    is_mounted "$path" || die "точка монтирования не смонтирована: $path"
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "установщик должен запускаться от root (войдите в Minimal CD и получите root-доступ)"
    fi
}

init_workdir() {
    ensure_dir "$GI_WORKDIR"
    chmod 0700 -- "$GI_WORKDIR"
    log_init
    exec 9>"${GI_WORKDIR}/lock"
    if ! flock -n 9; then
        die "другой экземпляр установщика уже работает (${GI_WORKDIR}/lock)"
    fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

config_defaults() {
    CFG_SCHEMA=1
    if [[ -d /sys/firmware/efi ]]; then
        CFG_BOOT_MODE=uefi
    else
        CFG_BOOT_MODE=bios
    fi
    CFG_DISK_MODE=auto
    CFG_DISK=""
    CFG_ROOT_FS=xfs
    CFG_HOME_FS=xfs
    CFG_SWAP_MODE=auto
    CFG_SWAP_MIB=0
    CFG_HOME_MODE=no
    CFG_HOME_MIB=0
    CFG_PART_ESP=""
    CFG_PART_BOOT=""
    CFG_PART_SWAP=""
    CFG_PART_ROOT=""
    CFG_PART_HOME=""
    CFG_FORMAT_ESP=yes
    CFG_FORMAT_BOOT=yes
    CFG_FORMAT_SWAP=yes
    CFG_FORMAT_ROOT=yes
    CFG_FORMAT_HOME=yes
    CFG_UUID_ESP=""
    CFG_UUID_BOOT=""
    CFG_UUID_SWAP=""
    CFG_UUID_ROOT=""
    CFG_UUID_HOME=""
    CFG_BOOT_FS=xfs
    CFG_STAGE_FLAVOR=openrc
    CFG_MIRROR="https://distfiles.gentoo.org"
    CFG_STAGE_URL=""
    CFG_PROFILE=stage
    CFG_DESKTOP=none
    CFG_CPU_FLAGS=yes
    CFG_UPDATE_WORLD=no
    CFG_MAKE_JOBS=auto
    CFG_CFLAGS="-march=native -O2 -pipe"
    CFG_VIDEO_CARDS=""
    CFG_USE_EXTRA=""
    CFG_KERNEL_MODE=bin
    CFG_FIRMWARE=yes
    CFG_MICROCODE=auto
    CFG_KERNEL_CMDLINE="quiet"
    CFG_BOOTLOADER=grub
    CFG_HOSTNAME=gentoo
    CFG_TIMEZONE=UTC
    CFG_LOCALE=en_US.UTF-8
    CFG_KEYMAP=us
    CFG_HWCLOCK=UTC
    CFG_NETWORK=dhcpcd
    CFG_SSH=no
    CFG_CRON=yes
    CFG_CHRONY=yes
    CFG_SYSLOG=yes
    CFG_SUDO=yes
    CFG_USERNAME=gentoo
    CFG_CREATE_USER=yes
}

config_key_valid() {
    local wanted=$1 key
    for key in "${CONFIG_KEYS[@]}"; do
        [[ $key == "$wanted" ]] && return 0
    done
    return 1
}

config_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

config_save() {
    local key var value tmp
    ensure_dir "$(dirname -- "$GI_CONFIG_FILE")"
    tmp=$(mktemp "${GI_CONFIG_FILE}.tmp.XXXXXX")
    {
        printf '# Gentoo TUI Installer configuration\n'
        printf '# Generated %s. Contains no passwords.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        for key in "${CONFIG_KEYS[@]}"; do
            var="CFG_${key}"
            value=${!var:-}
            if [[ $value == *$'\n'* || $value == *$'\r'* ]]; then
                die "значение ${key} содержит перевод строки и не может быть сохранено"
            fi
            printf '%s="%s"\n' "$key" "$(config_escape "$value")"
        done
    } >"$tmp"
    chmod 0600 -- "$tmp"
    mv -f -- "$tmp" "$GI_CONFIG_FILE"
    log_info "configuration saved to $GI_CONFIG_FILE"
}

config_load() {
    local file=$1 line key raw value
    [[ -f $file ]] || die "файл конфигурации не найден: $file"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
        if [[ ! $line =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=\"(([^\"\\]|\\.)*)\"[[:space:]]*(#.*)?$ ]]; then
            die "некорректная строка конфигурации: $line"
        fi
        key=${BASH_REMATCH[1]}
        raw=${BASH_REMATCH[2]}
        if ! config_key_valid "$key"; then
            die "неизвестный или небезопасный ключ конфигурации: $key"
        fi
        value=${raw//\\\"/\"}
        value=${value//\\\\/\\}
        printf -v "CFG_${key}" '%s' "$value"
    done <"$file"
    if [[ ${CFG_SCHEMA:-0} != 1 ]]; then
        die "неподдерживаемая версия конфигурации: ${CFG_SCHEMA:-unknown}"
    fi
    log_info "configuration loaded from $file"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

state_init() {
    local key
    STATE_DONE=()
    for key in "${STATE_STEPS[@]}"; do
        STATE_DONE["$key"]=0
    done
}

state_load() {
    local line key
    state_init
    [[ -f $GI_STATE_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([a-z0-9_]+)=done$ ]] || continue
        key=${BASH_REMATCH[1]}
        if [[ -n ${STATE_DONE[$key]+set} ]]; then
            STATE_DONE["$key"]=1
        fi
    done <"$GI_STATE_FILE"
}

state_save() {
    local tmp key
    tmp=$(mktemp "${GI_STATE_FILE}.tmp.XXXXXX")
    {
        printf '# Gentoo TUI Installer state; completed steps only.\n'
        for key in "${STATE_STEPS[@]}"; do
            if [[ ${STATE_DONE[$key]:-0} == 1 ]]; then
                printf '%s=done\n' "$key"
            fi
        done
    } >"$tmp"
    chmod 0600 -- "$tmp"
    mv -f -- "$tmp" "$GI_STATE_FILE"
}

state_mark_done() {
    local key=$1
    STATE_DONE["$key"]=1
    state_save
    log_info "step completed: $key"
}

state_is_done() {
    [[ ${STATE_DONE[$1]:-0} == 1 ]]
}

state_has_progress() {
    local key
    for key in "${STATE_STEPS[@]}"; do
        [[ ${STATE_DONE[$key]:-0} == 1 ]] && return 0
    done
    return 1
}

state_label() {
    case "$1" in
        disk) printf 'Разметка диска' ;;
        stage3) printf 'Stage3 и Portage' ;;
        portage) printf 'Chroot и настройка Portage' ;;
        kernel) printf 'Ядро Linux' ;;
        system) printf 'Настройка системы' ;;
        tools) printf 'Системные службы' ;;
        bootloader) printf 'Загрузчик GRUB' ;;
        desktop) printf 'Графическое окружение' ;;
        finalize) printf 'Завершение' ;;
        *) printf '%s' "$1" ;;
    esac
}

state_reset() {
    state_init
    rm -f -- "$GI_STATE_FILE"
}

config_derived() {
    if [[ $CFG_STAGE_FLAVOR == *systemd* ]]; then
        CFG_INIT=systemd
    else
        CFG_INIT=openrc
    fi
    # Desktop stage3 variants use the desktop profile unless the user selected
    # a more specific one (GNOME, KDE or hardened).
    if [[ $CFG_STAGE_FLAVOR == desktop-* && $CFG_PROFILE == stage ]]; then
        CFG_PROFILE=desktop
    fi
    # Keep the Portage profile consistent with the desktop environment choice
    # while preserving explicit KDE and hardened profiles. GNOME also replaces
    # the generic desktop profile because GDM requires elogind/systemd USE flags
    # that the GNOME profile enables.
    case "$CFG_DESKTOP" in
        xfce)
            [[ $CFG_PROFILE == stage ]] && CFG_PROFILE=desktop
            ;;
        gnome)
            if [[ $CFG_PROFILE == stage || $CFG_PROFILE == desktop ]]; then
                CFG_PROFILE=gnome
            fi
            ;;
    esac
    if [[ $CFG_SWAP_MODE != custom ]]; then
        CFG_SWAP_MIB=0
    fi
    # Drop fields that do not belong to the selected layout. This prevents a
    # stale partition or UUID from a previous attempt being mounted or written
    # to fstab after the user changes the layout.
    if [[ $CFG_BOOT_MODE == uefi ]]; then
        CFG_PART_BOOT=""
    else
        CFG_PART_ESP=""
    fi
    if [[ $CFG_HOME_MODE == no ]]; then
        CFG_PART_HOME=""
        CFG_FORMAT_HOME=no
    fi
    if [[ $CFG_SWAP_MODE == none ]]; then
        CFG_PART_SWAP=""
        CFG_FORMAT_SWAP=no
    fi
    [[ -n $CFG_PART_ESP ]] || CFG_UUID_ESP=""
    [[ -n $CFG_PART_BOOT ]] || CFG_UUID_BOOT=""
    [[ -n $CFG_PART_SWAP ]] || CFG_UUID_SWAP=""
    [[ -n $CFG_PART_ROOT ]] || CFG_UUID_ROOT=""
    [[ -n $CFG_PART_HOME ]] || CFG_UUID_HOME=""
}

# Run a user-provided command and abort the installation on failure.
must() {
    if ! "$@"; then
        die "команда завершилась с ошибкой: $(render_cmd "$@")"
    fi
}
