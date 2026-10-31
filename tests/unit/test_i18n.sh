#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/i18n.sh"
source "${GI_TEST_ROOT}/lib/ui.sh"

CATALOG="${GI_TEST_ROOT}/lib/lang/ru.tsv"
[[ -f $CATALOG ]] || {
    printf '  FAIL: Russian catalogue missing: %s\n' "$CATALOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    finish_tests
}

# The catalogue must stay a simple two-column TSV with no duplicate keys and
# no empty translations. Comments are allowed.
bad_rows=$(awk -F'\t' '!/^#/ && NF != 2 { print NR }' "$CATALOG" | wc -l)
assert_eq "0" "$bad_rows" "catalogue has two tab-separated columns"
duplicates=$(grep -v '^#' "$CATALOG" | cut -f1 | sort | uniq -d || true)
assert_eq "" "$duplicates" "catalogue has no duplicate English keys"
empty_rows=$(awk -F'\t' '!/^#/ && $2 == "" { print NR }' "$CATALOG" | wc -l)
assert_eq "0" "$empty_rows" "catalogue has no empty translations"
entries=$(grep -vc '^#' "$CATALOG" || true)
((entries > 700)) || {
    printf '  FAIL: catalogue is unexpectedly small: %s entries\n' "$entries"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}
TESTS_RUN=$((TESTS_RUN + 1))

# English is the default; Russian is optional.
i18n_init en
assert_eq "English" "$(i18n_language_label en)" "English label"
assert_eq "Main menu" "$(T 'Main menu')" "English is the source language"
assert_eq "Yes" "$(i18n_text 'Yes')" "English mode ignores the Russian catalogue"
assert_eq $'line 1\nline 2' "$(T 'line 1\nline 2')" \
    "English expands \\n escapes without arguments"
assert_eq '100%' "$(T '100%')" "English keeps percent signs literal"

i18n_init ru
assert_eq "Русский" "$(i18n_language_label ru)" "Russian label"
assert_eq "Главное меню" "$(T 'Main menu')" "Russian menu translation"
assert_eq "Этап уже завершён" "$(i18n_text 'Step already completed')" \
    "static strings use i18n_text"
assert_eq "Загрузка: UEFI · Диск: /dev/vda · ФС: xfs" \
    "$(T 'Boot: %s · Disk: %s · FS: %s' UEFI /dev/vda xfs)" \
    "Russian translation keeps printf placeholders"
assert_eq "Git: 100%" "$(T 'Git: %s' '100%')" "arguments are data, not format strings"

# A missing catalogue entry falls back to the English source.
assert_eq "not translated yet" "$(T 'not translated yet')" \
    "unknown keys fall back to English"

# Locale selection prefers Russian when available and falls back to a UTF-8
# locale otherwise. Generation is disabled here so the test is deterministic.
i18n_generate_locale() { return 1; }
GI_LOCALE_LIST=$'C.UTF-8\nru_RU.UTF-8'
assert_eq "ru_RU.UTF-8" "$(i18n_locale_for ru)" "Russian locale is preferred"
GI_LOCALE_LIST='C.UTF-8'
assert_eq "C.UTF-8" "$(i18n_locale_for ru)" "C.UTF-8 is the fallback"
assert_eq "C.UTF-8" "$(i18n_locale_for en)" "English uses the available UTF-8 locale"

# The language chooser must persist the choice and adjust only a default target
# locale, never an explicit user locale.
i18n_init en
config_defaults
CFG_UI_LANGUAGE=en
CFG_LOCALE=en_US.UTF-8
ui_menu() { UI_RESULT=ru; return 0; }
i18n_choose_language >/dev/null
assert_eq "ru" "$CFG_UI_LANGUAGE" "language chooser selects Russian"
assert_eq "ru_RU.UTF-8" "$CFG_LOCALE" "default target locale follows Russian"

i18n_init en
config_defaults
CFG_UI_LANGUAGE=en
CFG_LOCALE=de_DE.UTF-8
ui_menu() { UI_RESULT=ru; return 0; }
i18n_choose_language >/dev/null
assert_eq "de_DE.UTF-8" "$CFG_LOCALE" "explicit target locale is preserved"

# Action bar and compact summary required by the new interface.
i18n_init en
UI_MENU_SUMMARY=("Boot: UEFI · Disk: /dev/vda · FS: xfs")
bar=$(ui_action_bar)
assert_contains "$bar" "<Back>" "action bar has Back"
assert_contains "$bar" "<Next>" "action bar has Next"
assert_contains "$bar" "<Exit>" "action bar has Exit"
assert_contains "$bar" "<Save>" "action bar has Save"
assert_contains "$bar" "<Help>" "action bar has Help"
footer=$(ui_footer "Test hint")
assert_contains "$footer" "Test hint" "footer keeps its hint"
assert_contains "$footer" "<Help>" "footer includes the action bar"
summary=$(ui_summary)
assert_contains "$summary" "Current configuration" "summary has a heading"
assert_contains "$summary" "Boot: UEFI" "summary shows current settings"

# Action labels stay in the screenshot style in both languages.
i18n_init ru
bar=$(ui_action_bar)
for label in '<Back>' '<Next>' '<Exit>' '<Save>' '<Help>'; do
    assert_contains "$bar" "$label" "Russian action bar has ${label}"
done
i18n_init en

finish_tests
