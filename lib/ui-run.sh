# shellcheck shell=bash
# Command execution, failure handling, downloads and interactive programs.

ui_prepare_log() {
    local label=$1 slug
    GI_RUN_COUNTER=$((GI_RUN_COUNTER + 1))
    slug=${GI_CURRENT_STEP:-main}
    GI_LAST_LOG="${GI_LOG_DIR}/$(printf '%02d' "$GI_RUN_COUNTER")-${slug}.log"
    {
        printf '### %s\n' "$label"
        printf '### %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$GI_LAST_LOG"
    chmod 0600 -- "$GI_LAST_LOG"
}

ui_tail_log() {
    local file=$1 lines=${2:-20}
    tail -n "$lines" -- "$file" 2>/dev/null |
        tr -d '\r' |
        sed -E 's/\x1B\[[0-9;?]*[ -\/]*[@-~]//g' |
        grep -v '^[[:space:]]*$' |
        tail -n "$lines" || true
}

ui_last_log_line() {
    ui_tail_log "$1" 30 | tail -n 1
}

ui_failure_choice() {
    local label=$1 log=$2 status=$3 key line width
    while :; do
        ui_header "${C_RED}Ошибка${C_RESET}" "Команда завершилась с кодом ${status}"
        printf '  %s%s%s\n\n' "$C_BOLD" "$label" "$C_RESET"
        printf '  %sПоследние строки журнала:%s\n\n' "$C_DIM" "$C_RESET"
        width=$(( $(ui_width) - 6 ))
        while IFS= read -r line; do
            (( ${#line} > width )) && line="${line:0:width-1}…"
            printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
        done < <(ui_tail_log "$log" 16)
        ui_footer "R — повторить · L — полный журнал · A/Esc — прервать"
        ui_read_key || return 1
        key=$UI_KEY
        case "$key" in
            r|R) return 0 ;;
            l|L) ui_show_file "Журнал: $log" "$log" ;;
            a|A|esc|q|Q) return 1 ;;
        esac
    done
}

ui_wait_process() {
    local label=$1 log=$2 pid=$3
    local started=$SECONDS spin="|/-\\" frame=0 elapsed line width
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS - started))
        width=$(( $(ui_width) - 6 ))
        line=$(ui_last_log_line "$log")
        (( ${#line} > width )) && line="${line:0:width-1}…"
        ui_header "Выполняется" "$label"
        printf '  %s%c%s  %02d:%02d\n\n' "$C_CYAN$C_BOLD" "${spin:frame%4:1}" "$C_RESET" \
            "$((elapsed / 60))" "$((elapsed % 60))"
        if [[ -n $line ]]; then
            printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
        else
            printf '  %sПодготовка…%s\n' "$C_DIM" "$C_RESET"
        fi
        printf '\n  %sНе выключайте питание. Полный журнал: %s%s\n' "$C_DIM" "$log" "$C_RESET"
        frame=$((frame + 1))
        sleep 0.35
    done
    local status=0
    wait "$pid" || status=$?
    return "$status"
}

ui_run() {
    local label=$1
    shift
    local -a cmd=("$@")
    local status attempt=0 width command_line
    while :; do
        attempt=$((attempt + 1))
        ui_prepare_log "$label"
        command_line=$(render_cmd "${cmd[@]}")
        GI_LAST_COMMAND=$command_line
        log_info "CMD: $command_line"
        printf '$ %s\n\n' "$command_line" >>"$GI_LAST_LOG"
        if [[ ! -t 1 ]]; then
            "${cmd[@]}" < /dev/null >>"$GI_LAST_LOG" 2>&1
            status=$?
            if ((status == 0)); then
                return 0
            fi
            if ! ui_failure_choice "$label" "$GI_LAST_LOG" "$status"; then
                GI_ABORTED=1
                return 1
            fi
            continue
        fi

        "${cmd[@]}" < /dev/null >"$GI_LAST_LOG" 2>&1 &
        local pid=$!
        status=0
        ui_wait_process "$label" "$GI_LAST_LOG" "$pid" || status=$?
        if ((status == 0)); then
            log_info "OK: $label"
            return 0
        fi
        log_error "FAILED ($status): $command_line"
        if ! ui_failure_choice "$label" "$GI_LAST_LOG" "$status"; then
            GI_ABORTED=1
            return 1
        fi
    done
}

ui_run_input() {
    local label=$1 input=$2
    shift 2
    local -a cmd=("$@")
    local command_line status
    ui_prepare_log "$label"
    command_line=$(render_cmd "${cmd[@]}")
    GI_LAST_COMMAND=$command_line
    log_info "CMD (stdin hidden): $command_line"
    printf '$ %s\n\n' "$command_line" >>"$GI_LAST_LOG"
    status=0
    printf '%s\n' "$input" | "${cmd[@]}" >>"$GI_LAST_LOG" 2>&1 || status=$?
    if ((status != 0)); then
        log_error "FAILED ($status): $command_line"
        if ui_failure_choice "$label" "$GI_LAST_LOG" "$status"; then
            ui_run_input "$label" "$input" "${cmd[@]}"
            return
        fi
        GI_ABORTED=1
        return 1
    fi
    return 0
}

ui_interactive() {
    local label=$1
    shift
    local -a cmd=("$@")
    ui_prepare_log "$label"
    GI_LAST_COMMAND=$(render_cmd "${cmd[@]}")
    log_info "INTERACTIVE: $GI_LAST_COMMAND"
    printf '$ %s\n\n' "$GI_LAST_COMMAND" >>"$GI_LAST_LOG"
    ui_clear
    printf '%s\e[?25h\e[0m' "$C_RESET"
    printf '%s\n\n' "$label"
    local status=0
    "${cmd[@]}" < /dev/tty > /dev/tty 2>&1 || status=$?
    printf '\e[?25l'
    if ((status != 0)); then
        log_error "INTERACTIVE FAILED ($status): $GI_LAST_COMMAND"
        ui_error "Интерактивная команда завершилась с ошибкой" \
            "${label}\nКод возврата: ${status}\nЖурнал: ${GI_LAST_LOG}"
        return "$status"
    fi
    return 0
}

ui_human_bytes() {
    local bytes=${1:-0}
    if ((bytes >= 1073741824)); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f GiB", b/1073741824 }'
    elif ((bytes >= 1048576)); then
        awk -v b="$bytes" 'BEGIN { printf "%.1f MiB", b/1048576 }'
    elif ((bytes >= 1024)); then
        awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }'
    else
        printf '%d B' "$bytes"
    fi
}

ui_download() {
    local url=$1 dest=$2 expected=$3 label=$4
    local status size percent bar elapsed bytes_per_sec
    local started existing size_ok resume_retry=0
    ensure_dir "$(dirname -- "$dest")"
    if [[ -f $dest ]]; then
        existing=$(stat -c %s -- "$dest" 2>/dev/null || printf '0')
        if ((expected > 0)); then
            if ((existing == expected)); then
                log_info "download already complete: $dest"
                return 0
            fi
            if ((existing > expected)); then
                log_warn "removing oversized partial download: $dest ($existing > $expected)"
                rm -f -- "$dest"
            fi
        fi
    fi

    while :; do
        ui_prepare_log "Загрузка: $label"
        local log=$GI_LAST_LOG
        local -a cmd=(curl -fL --retry 2 --retry-delay 3 --connect-timeout 30
            --silent --show-error -o "$dest" "$url")
        if [[ -f $dest && -s $dest ]]; then
            cmd=(curl -fL --retry 2 --retry-delay 3 --connect-timeout 30
                --silent --show-error -C - -o "$dest" "$url")
        fi
        GI_LAST_COMMAND=$(render_cmd "${cmd[@]}")
        log_info "DOWNLOAD: $url -> $dest"
        printf '$ %s\n\n' "$GI_LAST_COMMAND" >>"$log"
        started=$SECONDS
        status=0
        "${cmd[@]}" < /dev/null >>"$log" 2>&1 &
        local pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            size=0
            [[ -f $dest ]] && size=$(stat -c %s -- "$dest" 2>/dev/null || printf '0')
            elapsed=$((SECONDS - started + 1))
            bytes_per_sec=$((size / elapsed))
            if ((expected > 0)); then
                percent=$((size * 100 / expected))
                ((percent > 100)) && percent=100
                bar=$(ui_progress_bar "$size" "$expected" 32)
            else
                percent=0
                bar=$(ui_progress_bar 1 1 32)
            fi
            ui_header "Загрузка" "$label"
            printf '  %s%s%s\n\n' "$C_DIM" "$url" "$C_RESET"
            if ((expected > 0)); then
                printf '  %s%s%s %3d%%\n' "$C_GREEN" "$bar" "$C_RESET" "$percent"
                printf '\n  %s из %s · %s/s\n' \
                    "$(ui_human_bytes "$size")" "$(ui_human_bytes "$expected")" "$(ui_human_bytes "$bytes_per_sec")"
            else
                printf '  %s%s%s\n' "$C_GREEN" "$bar" "$C_RESET"
                printf '\n  Скачано: %s · %s/s\n' "$(ui_human_bytes "$size")" "$(ui_human_bytes "$bytes_per_sec")"
            fi
            printf '\n  %sФайл: %s%s\n' "$C_DIM" "$dest" "$C_RESET"
            sleep 0.5
        done
        wait "$pid" || status=$?
        size=0
        [[ -f $dest ]] && size=$(stat -c %s -- "$dest" 2>/dev/null || printf '0')
        size_ok=0
        if ((expected > 0)); then
            ((size == expected)) && size_ok=1
        elif ((size > 0)); then
            size_ok=1
        fi
        if ((status == 0 && size_ok)); then
            log_info "download complete: $dest ($size bytes)"
            return 0
        fi
        # curl reports 33 when a resume range is not satisfiable. When the
        # server has no more data, the file is already complete (common for
        # sidecars and for direct URLs without a known expected size).
        if ((status == 33 && size > 0)) && { ((expected == 0)) || ((expected > 0 && size >= expected)); }; then
            log_info "download complete (resume reported EOF): $dest ($size bytes)"
            return 0
        fi
        if ((status == 33 && expected > 0 && size < expected && resume_retry == 0)); then
            log_warn "server does not support resume for $url; restarting download"
            rm -f -- "$dest"
            resume_retry=1
            continue
        fi
        if ((status == 0 && expected > 0 && size != expected)); then
            status=1
            printf 'Размер файла %s не совпадает с ожидаемым %s\n' "$size" "$expected" >>"$log"
        fi
        if ((status == 0 && expected == 0 && size == 0)); then
            status=1
            printf 'Сервер вернул пустой файл\n' >>"$log"
        fi
        log_error "download failed ($status): $url"
        if ! ui_failure_choice "Загрузка: $label" "$log" "$status"; then
            GI_ABORTED=1
            return 1
        fi
        status=0
    done
}
