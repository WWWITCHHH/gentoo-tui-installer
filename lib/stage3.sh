# shellcheck shell=bash
# Stage3 download, verification and extraction.

STAGE3_TARBALL=""
STAGE3_URL=""
STAGE3_SIZE=0
STAGE3_SHA256=""
STAGE3_ASC=""

stage3_mirror() {
    local mirror=${CFG_MIRROR%/}
    printf '%s' "$mirror"
}

stage3_latest_path() {
    printf 'releases/amd64/autobuilds/latest-stage3-amd64-%s.txt' "$CFG_STAGE_FLAVOR"
}

stage3_resolve() {
    local base latest_url latest_file line rel
    base=$(stage3_mirror)

    if [[ -n $CFG_STAGE_URL ]]; then
        STAGE3_URL=$CFG_STAGE_URL
        STAGE3_SIZE=0
        STAGE3_TARBALL="${GI_DOWNLOAD_DIR}/${STAGE3_URL##*/}"
        log_info "stage3 URL from configuration: $STAGE3_URL"
        return 0
    fi

    latest_file="${GI_DOWNLOAD_DIR}/latest-stage3-amd64-${CFG_STAGE_FLAVOR}.txt"
    latest_url="${base}/$(stage3_latest_path)"
    ui_download "$latest_url" "$latest_file" 0 "$(T 'Latest Stage3 list')" || return 1

    line=$(grep -E '^[0-9]{8}T[0-9]{6}Z/stage3-amd64-[^ ]+\.tar\.xz [0-9]+$' "$latest_file" | tail -n 1 || true)
    if [[ -z $line ]]; then
        ui_error "$(T 'Invalid Stage3 list')" \
            "$(T 'Could not find an archive path in %s. Check the mirror and the Stage3 variant.' "$latest_file")"
        return 1
    fi
    rel=${line%% *}
    STAGE3_SIZE=${line##* }
    STAGE3_URL="${base}/releases/amd64/autobuilds/${rel}"
    STAGE3_TARBALL="${GI_DOWNLOAD_DIR}/${rel##*/}"
    log_info "resolved stage3: $STAGE3_URL ($STAGE3_SIZE bytes)"
    return 0
}

stage3_fetch_sidecars() {
    local sha_url="${STAGE3_URL}.sha256"
    local asc_url="${STAGE3_URL}.asc"
    STAGE3_SHA256="${STAGE3_TARBALL}.sha256"
    STAGE3_ASC="${STAGE3_TARBALL}.asc"

    if curl -fsIL --max-time 25 "$sha_url" >/dev/null 2>&1; then
        ui_download "$sha_url" "$STAGE3_SHA256" 0 "$(T 'SHA256 checksum')" || return 1
    else
        log_warn "SHA256 sidecar not available: $sha_url"
        STAGE3_SHA256=""
    fi
    if curl -fsIL --max-time 25 "$asc_url" >/dev/null 2>&1; then
        ui_download "$asc_url" "$STAGE3_ASC" 0 "$(T 'GPG signature')" || return 1
    else
        log_warn "GPG signature not available: $asc_url"
        STAGE3_ASC=""
    fi
    if [[ -z $STAGE3_SHA256 && -z $STAGE3_ASC ]]; then
        die "$(T 'neither SHA256 nor a GPG signature is available for Stage3; installation is unsafe')"
    fi
    return 0
}

stage3_verify_sha256() {
    local expected actual
    [[ -n $STAGE3_SHA256 && -f $STAGE3_SHA256 ]] || return 0
    expected=$(grep -m1 -E '^[0-9a-f]{64}[[:space:]]+' "$STAGE3_SHA256" | awk '{print $1}' || true)
    if [[ -z $expected ]]; then
        ui_error "$(T 'SHA256 verification')" "$(T 'No checksum was found in %s.' "$STAGE3_SHA256")"
        return 1
    fi
    ui_header "$(T 'Integrity check')" "$(T 'Computing SHA256 for %s' "$(basename -- "$STAGE3_TARBALL")")"
    printf '  %s%s%s %s\n' "$C_DIM" "$(T 'Expected:')" "$C_RESET" "$expected"
    actual=$(sha256sum -- "$STAGE3_TARBALL" 2>/dev/null | awk '{print $1}')
    if [[ $actual != "$expected" ]]; then
        ui_error "$(T 'SHA256 verification failed')" \
            "$(T 'Expected: %s\nGot:      %s\nThe archive is corrupted or was replaced. Installation stopped.\nThe damaged file has been removed and will be downloaded again.' \
                "$expected" "${actual:-$(T 'none')}")"
        rm -f -- "$STAGE3_TARBALL"
        return 1
    fi
    printf '  %s%s %s ✓%s\n' "$C_GREEN" "$(T 'Got:')" "$actual" "$C_RESET"
    log_info "stage3 SHA256 verified: $actual"
    return 0
}

stage3_import_gentoo_key() {
    local key
    for key in /usr/share/openpgp-keys/gentoo-release.asc \
        /usr/share/openpgp-keys/gentoo-release-old.asc; do
        [[ -f $key ]] || continue
        if ! gpg --homedir "$GI_GNUPG_HOME" --batch --no-tty --import "$key" >>"$GI_LOG_FILE" 2>&1; then
            log_warn "failed to import Gentoo release key from $key"
            return 1
        fi
        return 0
    done
    return 1
}

stage3_verify_gpg() {
    [[ -n $STAGE3_ASC && -f $STAGE3_ASC ]] || return 0
    if ! command_exists gpg; then
        if [[ -z $STAGE3_SHA256 ]]; then
            die "$(T 'GPG is unavailable and no SHA256 checksum exists for Stage3')"
        fi
        warning_no_gpg
        return 0
    fi
    if ! stage3_import_gentoo_key; then
        if [[ -z $STAGE3_SHA256 ]]; then
            die "$(T 'the Gentoo key was not found and no SHA256 checksum exists for Stage3')"
        fi
        warning_no_gpg
        return 0
    fi
    ui_run "$(T 'Verifying the Stage3 signature')" gpg --homedir "$GI_GNUPG_HOME" --batch --no-tty \
        --verify "$STAGE3_ASC" "$STAGE3_TARBALL" || return 1
    log_info "stage3 GPG signature verified"
    return 0
}

warning_no_gpg() {
    warn "$(T 'the Gentoo release key was not found: the GPG signature was not checked, only SHA256 is used')"
    ui_msg "$(T 'GPG unavailable')" "$(T 'The Gentoo release key was not found on the Minimal CD.\nOnly the SHA256 checksum will be verified.')"
}

stage3_download() {
    local label
    label="Stage3 $(lower "$CFG_STAGE_FLAVOR")"
    log_info "stage3 download: $STAGE3_URL -> $STAGE3_TARBALL"
    ui_download "$STAGE3_URL" "$STAGE3_TARBALL" "$STAGE3_SIZE" "$label" || return 1
    return 0
}

stage3_extract() {
    require_mountpoint "$GI_ROOT"
    if [[ -e "$GI_ROOT/etc/os-release" ]]; then
        log_warn "stage3 overlay already present in $GI_ROOT"
    fi
    ui_run "$(T 'Extracting Stage3 to %s' "$GI_ROOT")" \
        tar --xattrs-include='*.*' --numeric-owner -xpvf "$STAGE3_TARBALL" -C "$GI_ROOT" || return 1
    ui_run "$(T 'Syncing Stage3 writes')" sync || true
    log_info "stage3 extracted to $GI_ROOT"
}

stage3_cleanup() {
    if [[ -n ${STAGE3_TARBALL:-} && -f $STAGE3_TARBALL ]]; then
        rm -f -- "$STAGE3_TARBALL" "${STAGE3_TARBALL}.sha256" "${STAGE3_TARBALL}.asc"
    fi
}

step_stage3() {
    require_mountpoint "$GI_ROOT"
    stage3_resolve || return 1
    stage3_fetch_sidecars || return 1
    stage3_download || return 1
    stage3_verify_sha256 || return 1
    stage3_verify_gpg || return 1
    stage3_extract || return 1
    config_save
}
