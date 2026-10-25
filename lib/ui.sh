# shellcheck shell=bash
# Self-contained ANSI TUI. No dialog/whiptail dependency.

if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    C_RESET=$'\e[0m'
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_MAGENTA=$'\e[35m'
    C_CYAN=$'\e[36m'
    C_WHITE=$'\e[37m'
    C_INVERSE=$'\e[7m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
    C_BLUE="" C_MAGENTA="" C_CYAN="" C_WHITE="" C_INVERSE=""
fi

UI_KEY=""
UI_CANCELLED=0
UI_INT_MIN=0
UI_INT_MAX=0

ui_init() {
    GI_UI_ACTIVE=1
    printf '\e[?25l'
}

ui_cleanup() {
    if [[ ${GI_UI_ACTIVE:-0} == 1 ]]; then
        printf '%s\e[?25h\e[0m' "$C_RESET"
        GI_UI_ACTIVE=0
    fi
}

ui_width() {
    local width=${COLUMNS:-0}
    if ((width < 40)); then
        width=$(tput cols 2>/dev/null || printf '80')
    fi
    ((width > 100)) && width=100
    ((width < 40)) && width=40
    printf '%d' "$width"
}

ui_height() {
    local height=${LINES:-0}
    if ((height < 15)); then
        height=$(tput lines 2>/dev/null || printf '24')
    fi
    ((height < 15)) && height=15
    printf '%d' "$height"
}

ui_clear() {
    printf '\e[H\e[2J'
}

ui_hr() {
    local char=${1:-─} spaces
    printf -v spaces '%*s' "$(ui_width)" ''
    printf '%s%s%s\n' "$C_DIM" "${spaces// /$char}" "$C_RESET"
}

ui_wrap() {
    local text=$1 width=${2:-$(( $(ui_width) - 4 ))}
    printf '%s\n' "$text" | fold -s -w "$width" | sed 's/^/  /'
}

ui_progress_bar() {
    local current=$1 total=$2 width=${3:-20}
    local filled empty bar="" i
    ((total < 1)) && total=1
    filled=$((current * width / total))
    ((filled > width)) && filled=width
    empty=$((width - filled))
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    printf '%s' "$bar"
}

ui_header() {
    local title=$1 subtitle=${2:-} width progress line
    width=$(ui_width)
    printf -v line '%*s' "$((width - 2))" ''
    line=${line// /─}
    ui_clear
    printf '%s╭%s╮%s\n' "$C_CYAN" "$line" "$C_RESET"
    printf '%s│%s %sGENTOO TUI INSTALLER%s' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    if ((GI_STEP_INDEX > 0)); then
        progress=$(ui_progress_bar "$GI_STEP_INDEX" "$GI_STEP_TOTAL" 14)
        printf '  %s[%s]%s %d/%d' "$C_GREEN" "$progress" "$C_RESET" "$GI_STEP_INDEX" "$GI_STEP_TOTAL"
    fi
    printf '\n%s╰%s╯%s\n\n' "$C_CYAN" "$line" "$C_RESET"
    if [[ -n $title ]]; then
        printf '  %s%s%s\n' "$C_BOLD$C_WHITE" "$title" "$C_RESET"
    fi
    if [[ -n $subtitle ]]; then
        printf '  %s%s%s\n' "$C_DIM" "$subtitle" "$C_RESET"
    fi
    printf '\n'
}

ui_footer() {
    local hint=${1:-"↑/↓ — выбор · Enter — подтвердить · Esc — назад"}
    printf '\n%s  %s%s\n' "$C_DIM" "$hint" "$C_RESET"
}

ui_read_key() {
    UI_KEY=""
    IFS= read -rsn1 UI_KEY || return 1
    if [[ $UI_KEY == $'\e' ]]; then
        local seq=""
        IFS= read -rsn2 -t 0.08 seq || true
        case "$seq" in
            '[A') UI_KEY=up ;;
            '[B') UI_KEY=down ;;
            '[C') UI_KEY=right ;;
            '[D') UI_KEY=left ;;
            '[H') UI_KEY=home ;;
            '[F') UI_KEY=end ;;
            *) UI_KEY=esc ;;
        esac
    elif [[ -z $UI_KEY ]]; then
        UI_KEY=enter
    elif [[ $UI_KEY == $'\x7f' || $UI_KEY == $'\b' ]]; then
        UI_KEY=backspace
    elif [[ $UI_KEY == $'\x15' ]]; then
        UI_KEY=clear
    elif [[ $UI_KEY == $'\x17' ]]; then
        UI_KEY=word
    fi
    return 0
}

ui_menu() {
    local title=$1 subtitle=$2 default_tag=$3
    shift 3
    local -a items=("$@") tags=() labels=() notes=()
    local item tag label note
    for item in "${items[@]}"; do
        tag="" label="" note=""
        IFS='|' read -r tag label note <<<"$item"
        [[ -z $tag ]] && continue
        tags+=("$tag")
        labels+=("$label")
        notes+=("$note")
    done
    ((${#tags[@]} > 0)) || die "ui_menu: нет пунктов меню"

    local selected=0 i
    for i in "${!tags[@]}"; do
        if [[ ${tags[$i]} == "$default_tag" ]]; then
            selected=$i
            break
        fi
    done

    local page_size offset=0 page_end note max_len key
    page_size=$(( $(ui_height) - 11 ))
    ((page_size < 5)) && page_size=5
    while :; do
        if ((selected < offset)); then offset=$selected; fi
        if ((selected >= offset + page_size)); then offset=$((selected - page_size + 1)); fi
        page_end=$((offset + page_size))
        ((page_end > ${#tags[@]})) && page_end=${#tags[@]}

        ui_header "$title" "$subtitle"
        for ((i = offset; i < page_end; i++)); do
            max_len=$(( $(ui_width) - 12 ))
            label=${labels[$i]}
            (( ${#label} > max_len )) && label="${label:0:max_len-1}…"
            if ((i == selected)); then
                printf '  %s❯ %d. %s%s\n' "$C_CYAN$C_BOLD" "$((i + 1))" "$label" "$C_RESET"
            else
                printf '    %s%d.%s %s\n' "$C_DIM" "$((i + 1))" "$C_RESET" "$label"
            fi
        done
        if (( ${#tags[@]} > page_size )); then
            printf '\n%s  Показаны %d–%d из %d%s\n' "$C_DIM" "$((offset + 1))" "$page_end" "${#tags[@]}" "$C_RESET"
        fi
        note=${notes[$selected]}
        if [[ -n $note ]]; then
            printf '\n'
            ui_wrap "$note"
        fi
        ui_footer
        if ! ui_read_key; then
            UI_CANCELLED=1
            return 1
        fi
        key=$UI_KEY
        case "$key" in
            up)
                ((selected > 0)) && selected=$((selected - 1))
                ;;
            down)
                ((selected < ${#tags[@]} - 1)) && selected=$((selected + 1))
                ;;
            home) selected=0 ;;
            end) selected=$((${#tags[@]} - 1)) ;;
            enter)
                UI_RESULT=${tags[$selected]}
                UI_CANCELLED=0
                return 0
                ;;
            esc|left|q)
                UI_CANCELLED=1
                return 1
                ;;
            [1-9])
                i=$((offset + key - 1))
                if ((i < ${#tags[@]})); then
                    UI_RESULT=${tags[$i]}
                    UI_CANCELLED=0
                    return 0
                fi
                ;;
        esac
    done
}

ui_confirm() {
    local title=$1 question=$2 default=${3:-yes}
    local default_tag=yes
    [[ $default == no ]] && default_tag=no
    if ui_menu "$title" "$question" "$default_tag" \
        "yes|Да|Подтвердить действие" \
        "no|Нет|Вернуться без изменений"; then
        [[ $UI_RESULT == yes ]]
        return
    fi
    return 1
}

ui_msg() {
    local title=$1 body=${2:-}
    ui_header "$title"
    ui_wrap "$body"
    ui_footer "Enter — продолжить"
    ui_read_key || true
}

ui_error() {
    local title=$1 body=${2:-}
    ui_header "$C_RED$title$C_RESET"
    ui_wrap "$body"
    ui_footer "Enter — закрыть"
    ui_read_key || true
}

ui_pause() {
    ui_footer "${1:-Enter — продолжить}"
    ui_read_key || true
}

ui_show_file() {
    local title=$1 file=$2
    printf '%s\e[?25h\e[0m' "$C_RESET"
    ui_clear
    printf '%s%s%s\n\n' "$C_BOLD$C_CYAN" "$title" "$C_RESET"
    if command -v less >/dev/null 2>&1; then
        LESS=FRX less -R -- "$file" || true
    else
        sed -n '1,300p' -- "$file" || true
    fi
    printf '\n'
    printf '%s\e[?25l' "$C_RESET"
    ui_pause "Enter — вернуться"
}

ui_input() {
    local title=$1 prompt=$2 default=$3 validator=${4:-} hint=${5:-} masked=${6:-no}
    local value=$default error="" display max_len key i
    UI_CANCELLED=0
    UI_RESULT=""
    while :; do
        ui_header "$title"
        ui_wrap "$prompt"
        if [[ -n $hint ]]; then
            printf '\n%s  %s%s\n' "$C_DIM" "$hint" "$C_RESET"
        fi
        printf '\n  %s›%s ' "$C_CYAN" "$C_RESET"
        if [[ $masked == yes && -n $value ]]; then
            display="••••••••"
        else
            display=$value
        fi
        max_len=$(( $(ui_width) - 8 ))
        if (( ${#display} > max_len )); then
            display="…${display: -max_len}"
        fi
        printf '%s%s%s' "$C_BOLD" "$display" "$C_RESET"
        if (( ${#display} < max_len )); then
            printf '%s▌%s' "$C_CYAN" "$C_RESET"
        fi
        printf '\n'
        if [[ -n $error ]]; then
            printf '\n  %s✖ %s%s\n' "$C_RED" "$error" "$C_RESET"
        fi
        ui_footer "Enter — принять · Ctrl-U — очистить · Esc — отмена"
        if ! ui_read_key; then
            UI_CANCELLED=1
            return 1
        fi
        key=$UI_KEY
        case "$key" in
            enter)
                if [[ -n $validator ]] && ! "$validator" "$value"; then
                    error=$VALIDATION_MESSAGE
                    continue
                fi
                error=""
                UI_RESULT=$value
                UI_CANCELLED=0
                return 0
                ;;
            esc|left)
                UI_CANCELLED=1
                return 1
                ;;
            backspace)
                value=${value%?}
                error=""
                ;;
            clear)
                value=""
                error=""
                ;;
            word)
                value=${value% *}
                ;;
            *)
                if [[ $key =~ ^[[:print:]]$ ]] && (( ${#value} < 512 )); then
                    value+=$key
                    error=""
                fi
                ;;
        esac
    done
}

ui_int_input() {
    local title=$1 prompt=$2 default=$3 min=$4 max=$5
    UI_INT_MIN=$min
    UI_INT_MAX=$max
    ui_input "$title" "$prompt" "$default" _ui_validate_int_range "Целое число от ${min} до ${max}" no
}

_ui_validate_int_range() {
    validate_int_range "$1" "$UI_INT_MIN" "$UI_INT_MAX" 2>/dev/null && return 0
    VALIDATION_MESSAGE="Введите целое число от ${UI_INT_MIN} до ${UI_INT_MAX}."
    return 1
}

ui_password() {
    local title=$1 prompt=$2
    ui_input "$title" "$prompt" "" validate_nonempty \
        "Ввод скрыт. Пароль не сохраняется на диск." yes
}

ui_password_twice() {
    local title=$1 first second
    while :; do
        ui_password "$title" "Введите пароль:" || return 1
        first=$UI_RESULT
        ui_password "$title" "Повторите пароль:" || return 1
        second=$UI_RESULT
        if [[ $first == "$second" ]]; then
            UI_SECRET=$first
            unset first second
            UI_RESULT=""
            return 0
        fi
        ui_error "Пароли не совпадают" "Повторите ввод."
    done
}

ui_step_intro() {
    local index=$1 total=$2 title=$3 body=$4
    GI_STEP_INDEX=$index
    GI_STEP_TOTAL=$total
    ui_header "Этап ${index} из ${total}: ${title}" "$body"
    ui_pause "Enter — начать этап"
}

ui_readonly() {
    printf '%s' "$C_DIM$1$C_RESET"
}
