#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/text.sh"

assert_eq "plain text" "$(T 'plain text')" "plain strings pass through"
assert_eq "Yes" "$(text 'Yes')" "static text passes through"
assert_eq "100%" "$(T '100%')" "percent signs remain literal"
assert_eq "Git: 100%" "$(T 'Git: %s' '100%')" "arguments are data, not format strings"
assert_eq $'line 1\nline 2' "$(T 'line 1\nline 2')" "backslash-n expands without arguments"
assert_eq $'a\nb' "$(text $'a\nb')" "literal newlines pass through"
assert_eq "a  b" "$(text 'a  b')" "spacing is preserved"
assert_eq "value = 42" "$(T 'value = %s' 42)" "printf formatting works"

finish_tests
