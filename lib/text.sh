# shellcheck shell=bash
# English-only text formatting helpers.
#
# Static strings pass through unchanged. T expands \n escapes and applies
# printf arguments; arguments are data, never a format string.

text() {
    printf '%s' "${1:-}"
}

text_format() {
    local key=$1 out
    shift
    if (($# == 0)); then
        printf '%b' "$key"
        return 0
    fi
    # shellcheck disable=SC2059
    printf -v out "$key" "$@"
    printf '%s' "$out"
}

T() { text_format "$@"; }
