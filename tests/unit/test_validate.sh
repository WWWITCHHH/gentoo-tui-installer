#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"

assert_ok "hostname simple" validate_hostname gentoo
assert_ok "hostname fqdn" validate_hostname host.example.org
assert_fail "hostname empty" validate_hostname ""
assert_fail "hostname leading dash" validate_hostname -bad
assert_fail "hostname spaces" validate_hostname "bad host"

assert_ok "username" validate_username alice
assert_ok "username underscore" validate_username _builder
assert_fail "username root" validate_username root
assert_fail "username uppercase" validate_username Alice

assert_ok "timezone UTC" validate_timezone UTC
assert_ok "timezone Europe/Moscow" validate_timezone Europe/Moscow
assert_fail "timezone invalid" validate_timezone Not/AZone
assert_fail "timezone traversal" validate_timezone ../../etc/passwd

assert_ok "locale en_US" validate_locale en_US.UTF-8
assert_ok "locale ru_RU" validate_locale ru_RU.UTF-8
assert_ok "locale C" validate_locale C.UTF-8
assert_fail "locale latin1" validate_locale en_US.ISO-8859-1

assert_ok "URL https" validate_url https://distfiles.gentoo.org
assert_ok "URL http" validate_url http://example.invalid/x
assert_fail "URL ftp" validate_url ftp://example.invalid/x
assert_ok "optional URL empty" validate_optional_url ""
assert_ok "optional tokens empty" validate_optional_tokens ""
assert_ok "optional tokens values" validate_optional_tokens "amdgpu radeonsi"
assert_fail "optional tokens space only" validate_optional_tokens " "
assert_fail "optional tokens semicolon" validate_optional_tokens "foo;bar"

assert_ok "mib" validate_mib 1024
assert_fail "mib zero" validate_mib 0
assert_fail "mib word" validate_mib plenty
assert_ok "range" validate_int_range 8 1 16
assert_fail "range low" validate_int_range 0 1 16
assert_fail "range high" validate_int_range 17 1 16

assert_ok "USE flags" validate_use_flags "cups bluetooth -kde"
assert_ok "USE flags empty" validate_use_flags ""
assert_fail "USE flags quote" validate_use_flags 'foo"bar'
assert_ok "CFLAGS" validate_cflags "-march=native -O2 -pipe"
assert_fail "CFLAGS quotes" validate_cflags '-O2 -DNAME="x"'
assert_ok "kernel cmdline" validate_kernel_cmdline "quiet splash"
assert_fail "kernel cmdline quote" validate_kernel_cmdline 'quiet "x"'
assert_fail "kernel cmdline dollar" validate_kernel_cmdline 'quiet $root'
assert_fail "kernel cmdline backtick" validate_kernel_cmdline 'quiet `id`'
assert_fail "kernel cmdline backslash" validate_kernel_cmdline 'quiet \x'
assert_fail "kernel cmdline newline" validate_kernel_cmdline $'quiet\nsplash'
assert_fail "kernel cmdline carriage return" validate_kernel_cmdline $'quiet\rsplash'
assert_ok "bool yes" validate_bool yes
assert_ok "bool no" validate_bool no
assert_fail "bool true" validate_bool true

VALIDATION_MESSAGE=""
assert_ok "hostname after reset" validate_hostname gentoo
assert_eq "" "$VALIDATION_MESSAGE" "successful validators leave no message"
assert_fail "validation message set" validate_hostname "bad host"
[[ -n $VALIDATION_MESSAGE ]] || { printf '  FAIL: validation message not set\n'; TESTS_FAILED=$((TESTS_FAILED + 1)); }
TESTS_RUN=$((TESTS_RUN + 1))

finish_tests
