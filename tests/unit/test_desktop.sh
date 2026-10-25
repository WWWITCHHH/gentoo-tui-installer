#!/usr/bin/env bash
set -Eeuo pipefail
source "${GI_TEST_ROOT}/tests/harness.sh"
source "${GI_TEST_ROOT}/lib/core.sh"
source "${GI_TEST_ROOT}/lib/validate.sh"
source "${GI_TEST_ROOT}/lib/tools.sh"
source "${GI_TEST_ROOT}/lib/portage.sh"
source "${GI_TEST_ROOT}/lib/desktop.sh"
source "${GI_TEST_ROOT}/lib/preflight.sh"

config_defaults
config_derived
assert_eq "none" "$CFG_DESKTOP" "desktop defaults to none"
assert_fail "desktop disabled" desktop_is_enabled

CFG_DESKTOP=xfce
assert_ok "desktop enabled" desktop_is_enabled
assert_eq "XFCE" "$(desktop_label)"
assert_eq "lightdm" "$(desktop_display_manager)"
xfce_packages=$(desktop_packages)
assert_contains "$xfce_packages" "x11-base/xorg-server" "XFCE pulls Xorg"
assert_contains "$xfce_packages" "xfce-base/xfce4-meta" "XFCE meta package"
assert_contains "$xfce_packages" "x11-misc/lightdm" "XFCE uses LightDM"
assert_contains "$xfce_packages" "x11-misc/lightdm-gtk-greeter" "LightDM greeter"
assert_contains "$xfce_packages" "sys-auth/elogind" "OpenRC XFCE needs elogind"
assert_not_contains "$xfce_packages" "gnome-base/gnome" "XFCE does not pull GNOME"

CFG_DESKTOP=gnome
CFG_INIT=openrc
assert_eq "GNOME" "$(desktop_label)"
assert_eq "gdm" "$(desktop_display_manager)"
gnome_openrc=$(desktop_packages)
assert_contains "$gnome_openrc" "gnome-base/gnome" "GNOME meta package"
assert_contains "$gnome_openrc" "gnome-base/gdm" "GNOME uses GDM"
assert_contains "$gnome_openrc" "sys-apps/dbus" "OpenRC GNOME needs dbus"
assert_contains "$gnome_openrc" "sys-auth/elogind" "OpenRC GNOME needs elogind"

CFG_INIT=systemd
gnome_systemd=$(desktop_packages)
assert_contains "$gnome_systemd" "gnome-base/gnome"
assert_contains "$gnome_systemd" "sys-apps/dbus" "systemd desktop still needs dbus"
assert_not_contains "$gnome_systemd" "sys-auth/elogind" "systemd does not need elogind"

CFG_DESKTOP=none
assert_eq "" "$(desktop_display_manager)" "no display manager without desktop"
assert_eq "" "$(desktop_packages)" "no packages without desktop"

# OpenRC desktops must enable elogind even with an explicit hardened profile,
# because LightDM/GDM have REQUIRED_USE="^^ ( elogind systemd )".
GI_ROOT="${GI_TEST_TMP}/make-conf-root"
rm -rf -- "$GI_ROOT"
mkdir -p "$GI_ROOT/etc"
config_defaults
CFG_DESKTOP=xfce
CFG_INIT=openrc
CFG_USE_EXTRA="cups bluetooth"
portage_write_make_conf
make_conf=$(<"$GI_ROOT/etc/portage/make.conf")
assert_contains "$make_conf" "USE='cups bluetooth elogind'" "OpenRC desktop adds elogind USE"

config_defaults
CFG_DESKTOP=gnome
CFG_INIT=systemd
portage_write_make_conf
make_conf=$(<"$GI_ROOT/etc/portage/make.conf")
assert_not_contains "$make_conf" "elogind" "systemd desktop does not add elogind USE"

# OpenRC display-manager configuration and enablement.
GI_ROOT="${GI_TEST_TMP}/desktop-root"
rm -rf -- "$GI_ROOT"
mkdir -p "$GI_ROOT/etc/init.d" "$GI_ROOT/usr/bin" "$GI_ROOT/usr/sbin"
: >"$GI_ROOT/etc/init.d/display-manager"
chroot_run() { printf '%s\n' "$*" >>"${GI_TEST_TMP}/chroot.log"; }
chroot_capture() { return 0; }
ui_error() { :; }
: >"${GI_TEST_TMP}/chroot.log"

CFG_DESKTOP=xfce
CFG_INIT=openrc
assert_ok "write LightDM display-manager config" desktop_write_display_manager
conf=$(<"$GI_ROOT/etc/conf.d/display-manager")
assert_contains "$conf" 'DISPLAYMANAGER="lightdm"' "display-manager selects LightDM"
assert_contains "$(<"${GI_TEST_TMP}/chroot.log")" \
    "rc-update add display-manager default" "display-manager enabled on OpenRC"

: >"${GI_TEST_TMP}/chroot.log"
CFG_DESKTOP=gnome
CFG_INIT=systemd
assert_ok "enable GDM on systemd" desktop_write_display_manager
log=$(<"${GI_TEST_TMP}/chroot.log")
assert_contains "$log" "systemctl enable gdm.service" "GDM service enabled"
assert_contains "$log" "systemctl set-default graphical.target" "graphical target selected"

# OpenRC services are enabled with the right runlevels.
: >"$GI_ROOT/etc/init.d/dbus"
: >"$GI_ROOT/etc/init.d/elogind"
: >"${GI_TEST_TMP}/chroot.log"
assert_ok "enable OpenRC desktop services" desktop_configure_openrc
log=$(<"${GI_TEST_TMP}/chroot.log")
assert_contains "$log" "rc-update add dbus default"
assert_contains "$log" "rc-update add elogind boot"

# Existing graphical groups are added to the installer user.
CFG_CREATE_USER=yes
CFG_USERNAME=alice
chroot_capture() {
    case "$*" in
        *"getent group plugdev"*) printf 'plugdev:x:1:\n' ;;
        *"getent group render"*) printf 'render:x:2:\n' ;;
        *"getent group video"*) printf 'video:x:3:\n' ;;
        *) : ;;
    esac
}
: >"${GI_TEST_TMP}/chroot.log"
assert_ok "add desktop groups" desktop_add_user_groups
assert_contains "$(<"${GI_TEST_TMP}/chroot.log")" \
    "usermod -aG plugdev,render,video alice" "desktop groups applied"

# Verification checks the session, Xorg and display manager binaries.
: >"$GI_ROOT/usr/bin/Xorg"
: >"$GI_ROOT/usr/bin/startxfce4"
: >"$GI_ROOT/usr/bin/gnome-session"
: >"$GI_ROOT/usr/sbin/lightdm"
: >"$GI_ROOT/usr/sbin/gdm"
CFG_DESKTOP=xfce
CFG_INIT=openrc
assert_ok "verify XFCE installation" desktop_verify
rm -f -- "$GI_ROOT/usr/bin/startxfce4"
assert_fail "verify missing XFCE session" desktop_verify
: >"$GI_ROOT/usr/bin/startxfce4"
CFG_DESKTOP=gnome
CFG_INIT=systemd
assert_ok "verify GNOME installation" desktop_verify
rm -f -- "$GI_ROOT/usr/sbin/gdm"
assert_fail "verify missing GDM" desktop_verify

# Network is required while a selected desktop step is still pending.
curl() { return 1; }
state_init
for step in stage3 portage kernel tools bootloader; do
    state_mark_done "$step"
done
CFG_DESKTOP=none
PREFLIGHT_LINES=()
PREFLIGHT_FAILED=0
PREFLIGHT_WARNED=0
preflight_network
assert_contains "${PREFLIGHT_LINES[0]}" "warn|" "network not needed when desktop is none"

CFG_DESKTOP=xfce
PREFLIGHT_LINES=()
PREFLIGHT_FAILED=0
PREFLIGHT_WARNED=0
preflight_network
assert_contains "${PREFLIGHT_LINES[0]}" "fail|" "network required for pending desktop"

state_mark_done desktop
PREFLIGHT_LINES=()
PREFLIGHT_FAILED=0
PREFLIGHT_WARNED=0
preflight_network
assert_contains "${PREFLIGHT_LINES[0]}" "warn|" "network not needed after desktop completed"

finish_tests
