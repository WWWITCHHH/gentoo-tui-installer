# shellcheck shell=bash
# Self-contained ANSI TUI. No dialog/whiptail dependency.
#
# The interface collects settings first and installs afterwards. Every screen
# therefore uses the same navigation model:
#   ↑/↓  move through the content; from the last item ↓ enters the action bar
#   ↑    from the action bar returns to the content
#   ←/→  move between action-bar buttons
#   Space selects an item in a choice window
#   Enter activates the focused item or button
#   F1 help, F2 save, F10 exit the current screen

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
UI_RESULT=""
UI_RESULTS=()
UI_PAGE_ROWS=()
UI_PAGE_MESSAGE=""
UI_CHOICE_QUICK=0

# Action bar button indices.
UI_ACTION_BACK=0
UI_ACTION_NEXT=1
UI_ACTION_SAVE=2
UI_ACTION_HELP=3
UI_ACTION_EXIT=4

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

# Renders the focusable bottom action bar. A focus index of -1 draws the bar
# without a highlighted button; 0..4 highlights Back, Next, Save, Help or Exit.
ui_action_bar() {
    local focus=${1:--1} i
    local -a labels=(
        "<Back>"
        "<Next>"
        "<Save> F2"
        "<Help> F1"
        "<Exit> F10"
    )
    printf '\n '
    for i in "${!labels[@]}"; do
        if ((i == focus)); then
            printf ' %s%s%s ' "$C_INVERSE$C_BOLD" "${labels[$i]}" "$C_RESET"
        else
            printf ' %s%s%s ' "$C_DIM$C_CYAN" "${labels[$i]}" "$C_RESET"
        fi
    done
    printf '\n'
}

ui_footer() {
    local hint action_focus=${2:--1}
    hint=$(i18n_text "${1:-↑/↓ — move · Enter — select · Esc — back}")
    printf '\n%s  %s%s\n' "$C_DIM" "$hint" "$C_RESET"
    ui_action_bar "$action_focus"
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
            '[Z') UI_KEY=backtab ;;
            '') UI_KEY=esc ;;
            *) UI_KEY=esc ;;
        esac
    elif [[ -z $UI_KEY ]]; then
        UI_KEY=enter
    elif [[ $UI_KEY == ' ' ]]; then
        UI_KEY=space
    elif [[ $UI_KEY == $'\t' ]]; then
        UI_KEY=tab
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

# Standardized marker used by choice windows.
#   single: ( ) / (*)
#   multi:  [ ] / [*]
ui_choice_marker() {
    local mode=$1 selected=$2
    if [[ $mode == multi ]]; then
        [[ $selected == 1 ]] && printf '[*]' || printf '[ ]'
        return 0
    fi
    [[ $selected == 1 ]] && printf '(*)' || printf '( )'
}

# Standardized single/multi choice window.
#
# Usage: ui_choice MODE TITLE SUBTITLE DEFAULT ITEM...
#   MODE    single|multi
#   DEFAULT tag for single, comma-separated tags for multi
#   ITEM    tag|label|note
#
# Space selects or toggles the focused item. Enter on an item selects it and
# moves focus to the Next button; Enter on Next confirms the window. Set
# UI_CHOICE_QUICK=1 to let Enter on a single-choice item confirm immediately
# (used by plain action menus such as the main menu).
ui_choice() {
    local mode=$1 title=$2 subtitle=$3 default=$4
    shift 4
    local -a items=("$@") tags=() labels=() notes=() marked=()
    local item tag label note i selected_index=-1
    title=$(i18n_text "$title")
    subtitle=$(i18n_text "$subtitle")
    for item in "${items[@]}"; do
        tag="" label="" note=""
        IFS='|' read -r tag label note <<<"$item"
        [[ -z $tag ]] && continue
        tags+=("$tag")
        labels+=("$(i18n_text "$label")")
        notes+=("$(i18n_text "$note")")
        marked+=(0)
    done
    ((${#tags[@]} > 0)) || die "ui_choice: no menu items"

    if [[ $mode == multi ]]; then
        local -a defaults=()
        IFS=',' read -r -a defaults <<<"$default"
        for tag in "${defaults[@]}"; do
            for i in "${!tags[@]}"; do
                [[ ${tags[$i]} == "$tag" ]] && marked[$i]=1
            done
        done
    else
        for i in "${!tags[@]}"; do
            if [[ ${tags[$i]} == "$default" ]]; then
                marked[$i]=1
                selected_index=$i
                break
            fi
        done
    fi

    local focus=0 action=-1 key page_size offset=0 page_end max_len summary_lines
    ((selected_index >= 0)) && focus=$selected_index
    while :; do
        if declare -F ui_on_summary >/dev/null 2>&1; then
            ui_on_summary
        fi
        summary_lines=${#UI_MENU_SUMMARY[@]}
        page_size=$(( $(ui_height) - 11 - summary_lines ))
        ((page_size < 4)) && page_size=4
        if ((focus < offset)); then offset=$focus; fi
        if ((focus >= offset + page_size)); then offset=$((focus - page_size + 1)); fi
        page_end=$((offset + page_size))
        ((page_end > ${#tags[@]})) && page_end=${#tags[@]}

        ui_header "$title" "$subtitle"
        max_len=$(( $(ui_width) - 12 ))
        for ((i = offset; i < page_end; i++)); do
            label=${labels[$i]}
            (( ${#label} > max_len )) && label="${label:0:max_len-1}…"
            local marker
            marker=$(ui_choice_marker "$mode" "${marked[$i]}")
            if ((action < 0 && i == focus)); then
                printf '  %s❯ %s %s%s\n' "$C_CYAN$C_BOLD" "$marker" "$label" "$C_RESET"
            else
                printf '    %s%s%s %s\n' "$C_DIM" "$marker" "$C_RESET" "$label"
            fi
        done
        if (( ${#tags[@]} > page_size )); then
            printf '\n%s  %s%s\n' "$C_DIM" \
                "$(T 'Showing %d–%d of %d' "$((offset + 1))" "$page_end" "${#tags[@]}")" "$C_RESET"
        fi
        note=${notes[$focus]}
        if [[ -n $note ]]; then
            printf '\n'
            ui_wrap "$note"
        fi
        ui_summary
        ui_footer "$(T '↑/↓ — move · Space — select · Enter — continue · Esc — back')" "$action"
        if ! ui_read_key; then
            UI_CANCELLED=1
            return 1
        fi
        key=$UI_KEY
        case "$key" in
            up)
                if ((action >= 0)); then
                    action=-1
                    focus=$page_end
                    ((focus >= ${#tags[@]})) && focus=$((${#tags[@]} - 1))
                else
                    ((focus > 0)) && focus=$((focus - 1))
                fi
                ;;
            down)
                if ((action < 0)); then
                    if ((focus < ${#tags[@]} - 1)); then
                        focus=$((focus + 1))
                    else
                        action=$UI_ACTION_NEXT
                    fi
                fi
                ;;
            home)
                ((action < 0)) && focus=0
                ;;
            end)
                ((action < 0)) && focus=$((${#tags[@]} - 1))
                ;;
            left|backtab)
                if ((action >= 0 && action > 0)); then
                    action=$((action - 1))
                fi
                ;;
            right|tab)
                if ((action >= 0 && action < UI_ACTION_EXIT)); then
                    action=$((action + 1))
                fi
                ;;
            space)
                if ((action < 0)); then
                    if [[ $mode == multi ]]; then
                        [[ ${marked[$focus]} == 1 ]] && marked[$focus]=0 || marked[$focus]=1
                    else
                        for i in "${!marked[@]}"; do marked[$i]=0; done
                        marked[$focus]=1
                    fi
                fi
                ;;
            enter)
                if ((action < 0)); then
                    if ((UI_CHOICE_QUICK)); then
                        # Action menus confirm the focused entry immediately.
                        for i in "${!marked[@]}"; do marked[$i]=0; done
                        marked[$focus]=1
                        UI_RESULT=${tags[$focus]}
                        UI_RESULTS=("$UI_RESULT")
                        UI_CANCELLED=0
                        return 0
                    fi
                    # A real choice is made with Space; Enter only continues to
                    # the action bar so it cannot silently change an answer.
                    action=$UI_ACTION_NEXT
                    continue
                fi
                case "$action" in
                    "$UI_ACTION_BACK")
                        UI_CANCELLED=1
                        return 1
                        ;;
                    "$UI_ACTION_NEXT")
                        if [[ $mode == multi ]]; then
                            UI_RESULTS=()
                            for i in "${!marked[@]}"; do
                                [[ ${marked[$i]} == 1 ]] && UI_RESULTS+=("${tags[$i]}")
                            done
                            UI_RESULT=${UI_RESULTS[0]:-}
                        else
                            UI_RESULTS=()
                            for i in "${!marked[@]}"; do
                                [[ ${marked[$i]} == 1 ]] && UI_RESULTS+=("${tags[$i]}")
                            done
                            # Navigating straight to Next without Space keeps the
                            # focused item as the answer; an explicit Space
                            # selection is always preserved.
                            if ((${#UI_RESULTS[@]} == 0)); then
                                marked[$focus]=1
                                UI_RESULTS=("${tags[$focus]}")
                            fi
                            UI_RESULT=${UI_RESULTS[0]}
                        fi
                        UI_CANCELLED=0
                        return 0
                        ;;
                    "$UI_ACTION_SAVE")
                        ui_save_action
                        ;;
                    "$UI_ACTION_HELP")
                        ui_show_help
                        ;;
                    "$UI_ACTION_EXIT")
                        UI_CANCELLED=1
                        return 1
                        ;;
                esac
                ;;
            help)
                ui_show_help
                ;;
            save)
                ui_save_action
                ;;
            esc|exit_action|q)
                UI_CANCELLED=1
                return 1
                ;;
            [1-9])
                if ((action < 0)); then
                    i=$((offset + key - 1))
                    if ((i < ${#tags[@]})); then
                        focus=$i
                    fi
                fi
                ;;
        esac
    done
}

# Plain action menu built on the standardized choice window. Enter on an item
# selects and confirms immediately, as expected from a list of actions.
ui_menu() {
    local title=$1 subtitle=$2 default_tag=$3
    shift 3
    local first=${1%%|*}
    [[ -z $default_tag ]] && default_tag=$first
    local previous=$UI_CHOICE_QUICK
    UI_CHOICE_QUICK=1
    ui_choice single "$title" "$subtitle" "$default_tag" "$@"
    local status=$?
    UI_CHOICE_QUICK=$previous
    return "$status"
}

ui_modal_confirm() {
    local title=$1 body=$2 default=${3:-no}
    local confirm_label=${4:-$(T 'Confirm')} cancel_label=${5:-$(T 'Cancel')}
    local focus=0 key width inner border line i
    [[ $default == yes ]] && focus=1
    title=$(i18n_text "$title")
    body=$(i18n_text "$body")
    width=$(ui_width)
    ((width > 76)) && width=76
    inner=$((width - 6))
    printf -v border '%*s' "$width" ''
    border=${border// /─}

    while :; do
        ui_header "$title" ""
        printf '  %s╭%s╮%s\n' "$C_CYAN" "$border" "$C_RESET"
        while IFS= read -r line; do
            local -a folded=()
            if [[ -z $line ]]; then
                printf '  %s│%s %-*s %s│%s\n' "$C_CYAN" "$C_RESET" "$inner" "" "$C_CYAN" "$C_RESET"
                continue
            fi
            mapfile -t folded < <(printf '%s\n' "$line" | fold -s -w "$inner")
            for line in "${folded[@]}"; do
                printf '  %s│%s %-*s %s│%s\n' "$C_CYAN" "$C_RESET" "$inner" "$line" "$C_CYAN" "$C_RESET"
            done
        done <<<"$body"
        printf '  %s╰%s╯%s\n' "$C_CYAN" "$border" "$C_RESET"
        printf '\n '
        for i in 0 1; do
            local label
            if ((i == 0)); then label=$cancel_label; else label=$confirm_label; fi
            if ((i == focus)); then
                printf ' %s%s%s ' "$C_INVERSE$C_BOLD" "$label" "$C_RESET"
            else
                printf ' %s%s%s ' "$C_DIM$C_CYAN" "$label" "$C_RESET"
            fi
        done
        printf '\n'
        printf '\n%s  %s%s\n' "$C_DIM" \
            "$(T '←/→ — choose · Enter — confirm · Esc — cancel')" "$C_RESET"
        if ! ui_read_key; then
            UI_CANCELLED=1
            return 1
        fi
        key=$UI_KEY
        case "$key" in
            left|backtab) focus=0 ;;
            right|tab) focus=1 ;;
            enter)
                if ((focus == 1)); then
                    UI_CANCELLED=0
                    return 0
                fi
                UI_CANCELLED=1
                return 1
                ;;
            help)
                ui_show_help
                ;;
            save)
                ui_save_action
                ;;
            esc|exit_action|q)
                UI_CANCELLED=1
                return 1
                ;;
        esac
    done
}

ui_confirm() {
    local title=$1 question=$2 default=${3:-yes}
    local default_tag=no
    [[ $default == yes ]] && default_tag=yes
    if ui_modal_confirm "$title" "$question" "$default_tag" \
        "$(T 'Yes')" "$(T 'No')"; then
        return 0
    fi
    return 1
}

ui_msg() {
    local title=$1 body=${2:-}
    if (( ${GI_UNATTENDED:-0} )); then
        log_info "message: $title"
        return 0
    fi
    ui_header "$title"
    ui_wrap "$body"
    ui_footer "$(T 'Enter — continue')"
    ui_read_key || true
}

ui_error() {
    local title=$1 body=${2:-}
    ui_header "$title" "" "$C_RED"
    ui_wrap "$body"
    ui_footer "$(T 'Enter — close')"
    ui_read_key || true
}

ui_pause() {
    # Installation is unattended after the review confirmation. Any pause left
    # on the normal path is a no-op so the process never waits for a key.
    if (( ${GI_UNATTENDED:-0} )); then
        UI_KEY=""
        return 0
    fi
    ui_footer "${1:-$(T 'Enter — continue')}"
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
    ui_pause "$(T 'Enter — back')"
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
        ui_footer "$(T 'Enter — accept · Ctrl-U — clear · Esc — cancel')"
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
        "$(T 'Input is hidden. The password is not written to disk.')" yes
}

ui_password_twice() {
    local title=$1 first second
    while :; do
        ui_password "$title" "$(T 'Enter password:')" || return 1
        first=$UI_RESULT
        ui_password "$title" "$(T 'Repeat password:')" || return 1
        second=$UI_RESULT
        if [[ $first == "$second" ]]; then
            UI_SECRET=$first
            unset first second
            UI_RESULT=""
            return 0
        fi
        ui_error "$(T 'Passwords do not match')" "$(T 'Please try again.')"
    done
}

ui_step_intro() {
    local index=$1 total=$2 title=$3 body=$4
    GI_STEP_INDEX=$index
    GI_STEP_TOTAL=$total
    ui_header "$(T 'Step %d of %d: %s' "$index" "$total" "$title")" "$body"
    if (( ${GI_UNATTENDED:-0} )); then
        return 0
    fi
    ui_pause "$(T 'Enter — start step')"
}

# ---------------------------------------------------------------------------
# Reusable form page
# ---------------------------------------------------------------------------
#
# ui_page_run TITLE SUBTITLE ROWS_FUNC EDIT_FUNC [VALIDATE_FUNC]
#
# ROWS_FUNC must populate the global UI_PAGE_ROWS array with rows in the form
#   tag|label|value|note
# EDIT_FUNC is called with the tag of the activated row. VALIDATE_FUNC is
# called before Next and may set UI_PAGE_MESSAGE to explain why the page cannot
# be left.
#
# Return values: 0 = Next, 1 = Back, 2 = Exit.
ui_page_run() {
    local title=$1 subtitle=$2 rows_func=$3 edit_func=$4 validate_func=${5:-}
    local focus=0 action=-1 key rc i page_size offset=0 page_end tag label value note
    local -a rows=()
    while :; do
        UI_PAGE_ROWS=()
        UI_PAGE_BODY=""
        "$rows_func"
        rows=("${UI_PAGE_ROWS[@]}")
        ((${#rows[@]})) || die "ui_page_run: no rows"
        ((focus >= ${#rows[@]})) && focus=$((${#rows[@]} - 1))
        page_size=$(( $(ui_height) - 9 ))
        ((page_size < 4)) && page_size=4
        if ((focus < offset)); then offset=$focus; fi
        if ((focus >= offset + page_size)); then offset=$((focus - page_size + 1)); fi
        page_end=$((offset + page_size))
        ((page_end > ${#rows[@]})) && page_end=${#rows[@]}

        ui_header "$title" "$subtitle"
        if [[ -n ${UI_PAGE_BODY:-} ]]; then
            ui_wrap "$UI_PAGE_BODY"
            printf '\n'
        fi
        for ((i = offset; i < page_end; i++)); do
            IFS='|' read -r tag label value note <<<"${rows[$i]}"
            label=$(i18n_text "$label")
            value=$(i18n_text "$value")
            if ((action < 0 && i == focus)); then
                printf '  %s❯ %s:%s %s%s\n' "$C_CYAN$C_BOLD" "$label" "$C_RESET" "$C_BOLD$C_WHITE" "$value"
                if [[ -n $note ]]; then
                    printf '      %s%s%s\n' "$C_DIM" "$(i18n_text "$note")" "$C_RESET"
                fi
            else
                printf '    %s%s:%s %s\n' "$C_DIM" "$label" "$C_RESET" "$value"
            fi
        done
        if (( ${#rows[@]} > page_size )); then
            printf '\n%s  %s%s\n' "$C_DIM" \
                "$(T 'Showing %d–%d of %d' "$((offset + 1))" "$page_end" "${#rows[@]}")" "$C_RESET"
        fi
        if [[ -n $UI_PAGE_MESSAGE ]]; then
            printf '\n  %s✖ %s%s\n' "$C_RED" "$(i18n_text "$UI_PAGE_MESSAGE")" "$C_RESET"
        fi
        ui_footer "$(T '↑/↓ — move · Enter — edit · Esc — back')" "$action"
        if ! ui_read_key; then
            UI_CANCELLED=1
            return 1
        fi
        key=$UI_KEY
        case "$key" in
            up)
                if ((action >= 0)); then
                    action=-1
                    focus=$page_end
                    ((focus >= ${#rows[@]})) && focus=$((${#rows[@]} - 1))
                else
                    ((focus > 0)) && focus=$((focus - 1))
                fi
                ;;
            down)
                if ((action < 0)); then
                    if ((focus < ${#rows[@]} - 1)); then
                        focus=$((focus + 1))
                    else
                        action=$UI_ACTION_NEXT
                    fi
                fi
                ;;
            home)
                ((action < 0)) && focus=0
                ;;
            end)
                ((action < 0)) && focus=$((${#rows[@]} - 1))
                ;;
            left|backtab)
                if ((action >= 0 && action > 0)); then action=$((action - 1)); fi
                ;;
            right|tab)
                if ((action >= 0 && action < UI_ACTION_EXIT)); then action=$((action + 1)); fi
                ;;
            enter)
                if ((action < 0)); then
                    IFS='|' read -r tag _ _ _ <<<"${rows[$focus]}"
                    UI_PAGE_MESSAGE=""
                    "$edit_func" "$tag" || true
                    continue
                fi
                case "$action" in
                    "$UI_ACTION_BACK")
                        UI_CANCELLED=1
                        return 1
                        ;;
                    "$UI_ACTION_NEXT")
                        if [[ -n $validate_func ]] && ! "$validate_func"; then
                            continue
                        fi
                        UI_CANCELLED=0
                        return 0
                        ;;
                    "$UI_ACTION_SAVE")
                        ui_save_action
                        ;;
                    "$UI_ACTION_HELP")
                        ui_show_help
                        ;;
                    "$UI_ACTION_EXIT")
                        UI_CANCELLED=1
                        return 2
                        ;;
                esac
                ;;
            help)
                ui_show_help
                ;;
            save)
                ui_save_action
                ;;
            esc|q)
                UI_CANCELLED=1
                return 1
                ;;
            exit_action)
                UI_CANCELLED=1
                return 2
                ;;
        esac
    done
}

ui_show_help() {
    if declare -F ui_on_help >/dev/null 2>&1; then
        ui_on_help
        return 0
    fi
    ui_msg "$(T 'Keyboard help')" \
        "$(T 'Arrow keys — move through items and the action bar\nDown on the last item — go to the action bar\nUp on the action bar — return to the items\nLeft/Right — choose an action-bar button\nSpace — select an item in a choice window\nEnter — edit a field or activate a button\nEsc — go back\nF1 — this help\nF2 or Ctrl-S — save the configuration\nF10 — exit the current page\n\nImportant actions always require a separate confirmation.')"
}

ui_save_action() {
    if declare -F ui_on_save >/dev/null 2>&1; then
        ui_on_save
        return 0
    fi
    ui_msg "$(T 'Save')" "$(T 'The configuration is saved automatically when the wizard changes a value.')"
}

ui_readonly() {
    printf '%s' "$C_DIM$1$C_RESET"
}
