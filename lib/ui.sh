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
UI_MENU_SUMMARY=()

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
    local text width=${2:-$(( $(ui_width) - 4 ))}
    text=$(i18n_text "${1:-}")
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
    local title subtitle title_color=${3:-} width progress line
    title=$(i18n_text "${1:-}")
    subtitle=$(i18n_text "${2:-}")
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
        printf '  %s%s%s%s\n' "$C_BOLD$C_WHITE" "$title_color" "$title" "$C_RESET"
    fi
    if [[ -n $subtitle ]]; then
        printf '  %s%s%s\n' "$C_DIM" "$subtitle" "$C_RESET"
    fi
    printf '\n'
}

ui_action_bar() {
    printf '\n%s  %s%s%s  %s%s%s  %s%s%s  %s%s%s\n' \
        "$C_DIM" \
        "$C_CYAN$C_BOLD" "$(T '<Select>')" "$C_DIM" \
        "$C_CYAN$C_BOLD" "$(T '<Exit>')" "$C_DIM" \
        "$C_CYAN$C_BOLD" "$(T '<Save>')" "$C_DIM" \
        "$C_CYAN$C_BOLD" "$(T '<Help>')" "$C_RESET"
}

ui_footer() {
    local hint
    hint=$(i18n_text "${1:-↑/↓ — choose · Enter — confirm · Esc — back}")
    printf '\n%s  %s%s\n' "$C_DIM" "$hint" "$C_RESET"
    ui_action_bar
}

ui_summary() {
    ((${#UI_MENU_SUMMARY[@]})) || return 0
    local line
    printf '\n%s  %s%s\n' "$C_DIM" "$(T 'Current configuration')" "$C_RESET"
    for line in "${UI_MENU_SUMMARY[@]}"; do
        printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    done
}

ui_read_key() {
    UI_KEY=""
    IFS= read -rsn1 UI_KEY || return 1
    if [[ $UI_KEY == $'\e' ]]; then
        local seq="" ch
        while IFS= read -rsn1 -t 0.04 ch; do
            seq+=$ch
        done
        case "$seq" in
            '[A'|'OA') UI_KEY=up ;;
            '[B'|'OB') UI_KEY=down ;;
            '[C'|'OC') UI_KEY=right ;;
            '[D'|'OD') UI_KEY=left ;;
            '[H'|'OH'|'[1~'|'[7~') UI_KEY=home ;;
            '[F'|'OF'|'[4~'|'[8~') UI_KEY=end ;;
            'OP'|'[11~'|'[[A') UI_KEY=help ;;
            'OQ'|'[12~'|'[[B') UI_KEY=save ;;
            '[21~') UI_KEY=exit_action ;;
            '') UI_KEY=esc ;;
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
    elif [[ $UI_KEY == $'\x13' ]]; then
        UI_KEY=save
    fi
    return 0
}

ui_menu() {
    local title=$1 subtitle=$2 default_tag=$3
    shift 3
    local -a items=("$@") tags=() labels=() notes=()
    local item tag label note
    title=$(i18n_text "$title")
    subtitle=$(i18n_text "$subtitle")
    for item in "${items[@]}"; do
        tag="" label="" note=""
        IFS='|' read -r tag label note <<<"$item"
        [[ -z $tag ]] && continue
        tags+=("$tag")
        labels+=("$(i18n_text "$label")")
        notes+=("$(i18n_text "$note")")
    done
    ((${#tags[@]} > 0)) || die "ui_menu: no menu items"

    local selected=0 i
    for i in "${!tags[@]}"; do
        if [[ ${tags[$i]} == "$default_tag" ]]; then
            selected=$i
            break
        fi
    done

    local page_size=5 offset=0 page_end note max_len key summary_lines
    while :; do
        if declare -F ui_on_summary >/dev/null 2>&1; then
            ui_on_summary
        fi
        summary_lines=${#UI_MENU_SUMMARY[@]}
        page_size=$(( $(ui_height) - 11 - summary_lines ))
        ((page_size < 5)) && page_size=5
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
            printf '\n%s  %s%s\n' "$C_DIM" \
                "$(T 'Showing %d–%d of %d' "$((offset + 1))" "$page_end" "${#tags[@]}")" "$C_RESET"
        fi
        note=${notes[$selected]}
        if [[ -n $note ]]; then
            printf '\n'
            ui_wrap "$note"
        fi
        ui_summary
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
            help)
                ui_show_help
                ;;
            save)
                ui_save_action
                ;;
            esc|left|q|exit_action)
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
        "yes|$(T 'Yes')|$(T 'Confirm the action')" \
        "no|$(T 'No')|$(T 'Return without changes')"; then
        [[ $UI_RESULT == yes ]]
        return
    fi
    return 1
}

ui_msg() {
    local title=$1 body=${2:-}
    ui_header "$title"
    ui_wrap "$body"
    ui_footer "Enter — continue"
    ui_read_key || true
}

ui_error() {
    local title=$1 body=${2:-}
    ui_header "$title" "" "$C_RED"
    ui_wrap "$body"
    ui_footer "Enter — close"
    ui_read_key || true
}

ui_pause() {
    ui_footer "${1:-Enter — continue}"
    ui_read_key || true
}

ui_show_file() {
    local title=$1 file=$2
    printf '%s\e[?25h\e[0m' "$C_RESET"
    ui_clear
    printf '%s%s%s\n\n' "$C_BOLD$C_CYAN" "$(i18n_text "$title")" "$C_RESET"
    if command -v less >/dev/null 2>&1; then
        LESS=FRX less -R -- "$file" || true
    else
        sed -n '1,300p' -- "$file" || true
    fi
    printf '\n'
    printf '%s\e[?25l' "$C_RESET"
    ui_pause "Enter — back"
}

ui_input() {
    local title=$1 prompt=$2 default=$3 validator=${4:-} hint=${5:-} masked=${6:-no}
    local value=$default error="" display max_len key i
    title=$(i18n_text "$title")
    prompt=$(i18n_text "$prompt")
    hint=$(i18n_text "$hint")
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
            printf '\n  %s✖ %s%s\n' "$C_RED" "$(i18n_text "$error")" "$C_RESET"
        fi
        ui_footer "Enter — accept · Ctrl-U — clear · Esc — cancel"
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
            help)
                ui_show_help
                ;;
            save)
                ui_save_action
                ;;
            esc|left|exit_action)
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
    ui_input "$title" "$prompt" "$default" _ui_validate_int_range \
        "$(T 'Integer from %d to %d' "$min" "$max")" no
}

_ui_validate_int_range() {
    validate_int_range "$1" "$UI_INT_MIN" "$UI_INT_MAX" 2>/dev/null && return 0
    VALIDATION_MESSAGE=$(T 'Enter an integer from %d to %d.' "$UI_INT_MIN" "$UI_INT_MAX")
    return 1
}

ui_password() {
    local title=$1 prompt=$2
    ui_input "$title" "$prompt" "" validate_nonempty \
        "Input is hidden. The password is not written to disk." yes
}

ui_password_twice() {
    local title=$1 first second
    while :; do
        ui_password "$title" "Enter password:" || return 1
        first=$UI_RESULT
        ui_password "$title" "Repeat password:" || return 1
        second=$UI_RESULT
        if [[ $first == "$second" ]]; then
            UI_SECRET=$first
            unset first second
            UI_RESULT=""
            return 0
        fi
        ui_error "Passwords do not match" "Please try again."
    done
}

ui_step_intro() {
    local index=$1 total=$2 title=$3 body=$4
    GI_STEP_INDEX=$index
    GI_STEP_TOTAL=$total
    ui_header "$(T 'Step %d of %d: %s' "$index" "$total" "$title")" "$body"
    ui_pause "Enter — start step"
}

ui_show_help() {
    if declare -F ui_on_help >/dev/null 2>&1; then
        ui_on_help
        return 0
    fi
    ui_msg "Keyboard help" \
        "Arrow keys — move in a menu
Enter — select or confirm
Esc — go back or leave the current screen
F1 — this help
F2 or Ctrl-S — save the configuration
F10 — exit the current menu

The bottom action bar always shows the available actions."
}

ui_save_action() {
    if declare -F ui_on_save >/dev/null 2>&1; then
        ui_on_save
        return 0
    fi
    ui_msg "Save" "The configuration is saved automatically when the wizard changes a value."
}

ui_readonly() {
    printf '%s' "$C_DIM$1$C_RESET"
}
