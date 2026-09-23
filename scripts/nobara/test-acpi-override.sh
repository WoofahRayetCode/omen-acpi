#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Nobara/Fedora test harness for a verified OMEN ACPI build archive.
# It deliberately manages one separate BLS entry for the running kernel.
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly BOOT_DIR="/boot"
readonly BLS_DIR="$BOOT_DIR/loader/entries"
readonly STATE_DIR="$BOOT_DIR/omen-acpi-nobara"
readonly MARKER="omen-acpi-nobara-test"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
    cat <<EOF
Usage:
  sudo $SCRIPT_NAME install <s5|combined> BUILD_ARCHIVE
  sudo $SCRIPT_NAME remove [s5|combined]
  $SCRIPT_NAME status

This is a Nobara-only test harness. It creates a separate GRUB BLS entry for
the currently running kernel and never changes the default boot entry.
EOF
}

require_root() {
    (( EUID == 0 )) || die "install and remove must be run as root."
}

require_nobara() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "nobara" ]] \
        || die "This helper is restricted to Nobara (detected ID=${ID:-unknown})."
}

require_commands() {
    local command
    for command in cpio iasl sha256sum tar; do
        command -v "$command" >/dev/null 2>&1 \
            || die "Required command is missing: $command"
    done
}

check_kernel_support() {
    local config="/boot/config-$(uname -r)"
    [[ -r "$config" ]] || die "Kernel configuration is missing: $config"
    grep -Fxq 'CONFIG_ACPI_TABLE_UPGRADE=y' "$config" \
        || die "$(uname -r) does not enable CONFIG_ACPI_TABLE_UPGRADE=y."
}

check_secure_boot() {
    if command -v mokutil >/dev/null 2>&1; then
        if mokutil --sb-state 2>/dev/null | grep -qi '^SecureBoot enabled'; then
            die "Secure Boot is enabled; this ACPI override test requires it disabled."
        fi
    fi
}

current_kernel_paths() {
    local kernel_version="$1"
    KERNEL_PATH="$BOOT_DIR/vmlinuz-$kernel_version"
    STOCK_INITRAMFS=''
    local candidate
    for candidate in \
        "$BOOT_DIR/initramfs-$kernel_version.img" \
        "$BOOT_DIR/initramfs-$kernel_version.img.zst" \
        "$BOOT_DIR/initramfs-$kernel_version.img.xz"; do
        if [[ -f "$candidate" ]]; then
            STOCK_INITRAMFS="$candidate"
            break
        fi
    done
    [[ -f "$KERNEL_PATH" ]] || die "Kernel image is missing: $KERNEL_PATH"
    [[ -n "$STOCK_INITRAMFS" ]] \
        || die "Could not find the stock initramfs for kernel $kernel_version."
}

extract_aml() {
    local archive="$1" destination="$2"
    [[ -f "$archive" && ! -L "$archive" ]] \
        || die "Build archive is missing or is a symlink: $archive"
    local archive_root
    archive_root="$(mktemp -d /tmp/omen-acpi-nobara.XXXXXX)"
    CLEANUP_PATHS+=("$archive_root")
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$archive_root"
    local -a matches=()
    mapfile -t matches < <(find "$archive_root" -type f -name DSDT.aml -print)
    ((${#matches[@]} == 1)) \
        || die "Expected exactly one regular DSDT.aml in the build archive."
    install -m 0644 "${matches[0]}" "$destination"
}

make_early_cpio() {
    local aml="$1" destination="$2" early_root
    early_root="$(mktemp -d /tmp/omen-acpi-nobara-early.XXXXXX)"
    CLEANUP_PATHS+=("$early_root")
    mkdir -p "$early_root/kernel/firmware/acpi"
    install -m 0644 "$aml" "$early_root/kernel/firmware/acpi/DSDT.aml"
    (
        cd "$early_root"
        printf '%s\0' kernel kernel/firmware kernel/firmware/acpi \
            kernel/firmware/acpi/DSDT.aml \
        | cpio --null --create --format=newc --owner=0:0 --quiet > "$destination"
    )
    chmod 0600 "$destination"
}

kernel_cmdline_options() {
    local arg options=''
    read -r -a cmdline_args <<<"$(< /proc/cmdline)"
    for arg in "${cmdline_args[@]}"; do
        case "$arg" in BOOT_IMAGE=*|initrd=*) continue ;; esac
        options+="${options:+ }$arg"
    done
    printf '%s\n' "$options"
}

safe_kernel_name() {
    local value="$1"
    value="${value//[^A-Za-z0-9._-]/_}"
    printf '%s\n' "$value"
}

entry_path() {
    local variant="$1" kernel_version="$2"
    printf '%s/%s-%s.conf\n' "$BLS_DIR" "$MARKER-$variant" "$(safe_kernel_name "$kernel_version")"
}

install_test_entry() {
    local variant="$1" archive="$2" kernel_version
    kernel_version="$(uname -r)"
    current_kernel_paths "$kernel_version"
    local work
    work="$(mktemp -d /tmp/omen-acpi-nobara-install.XXXXXX)"
    CLEANUP_PATHS+=("$work")
    local aml="$work/DSDT.aml" early="$work/early.cpio"
    local custom_initramfs="$STATE_DIR/$variant/$kernel_version/initramfs.img"
    local entry
    entry="$(entry_path "$variant" "$kernel_version")"
    [[ ! -e "$entry" ]] || die "Managed test entry already exists: $entry"
    mkdir -p "$STATE_DIR/$variant/$kernel_version"
    extract_aml "$archive" "$aml"
    iasl -d "$aml" -p "$work/check" >/dev/null 2>&1 \
        || die "iasl rejected the DSDT.aml from the build archive."
    make_early_cpio "$aml" "$early"
    cat "$early" "$STOCK_INITRAMFS" > "$work/initramfs.img"
    install -m 0600 "$work/initramfs.img" "$custom_initramfs"
    sha256sum "$custom_initramfs" > "$custom_initramfs.sha256"
    sha256sum "$aml" > "$STATE_DIR/$variant/$kernel_version/DSDT.sha256"
    local options
    options="$(kernel_cmdline_options)"
    cat > "$work/entry.conf" <<EOF
title Nobara OMEN ACPI $variant (test)
version $kernel_version
linux /vmlinuz-$kernel_version
initrd /omen-acpi-nobara/$variant/$kernel_version/initramfs.img
options $options
id $MARKER-$variant-$(safe_kernel_name "$kernel_version")
# $MARKER
EOF
    install -m 0644 "$work/entry.conf" "$entry"
    info "Installed separate Nobara test entry: Nobara OMEN ACPI $variant (test)"
    info "Stock entry and stock initramfs were not modified."
    info "Reboot and select the test entry manually from GRUB."
    info "Verify after boot with: journalctl -k -b | grep -E 'ACPI.*(override|upgrade|DSDT)'"
}

remove_entries() {
    local requested_variant="${1:-}" entry variant
    shopt -s nullglob
    for entry in "$BLS_DIR"/"$MARKER"-*.conf; do
        [[ -f "$entry" ]] || continue
        grep -Fxq "# $MARKER" "$entry" || continue
        variant="${entry##*${MARKER}-}"
        variant="${variant%%-*}"
        if [[ -n "$requested_variant" && "$variant" != "$requested_variant" ]]; then
            continue
        fi
        rm -f -- "$entry"
        rm -rf -- "$STATE_DIR/$variant"
        info "Removed managed Nobara test entry and payload: $variant"
    done
    shopt -u nullglob
}

show_status() {
    if [[ ! -d "$BLS_DIR" ]]; then
        info "Nobara BLS directory is absent: $BLS_DIR"
        return 0
    fi
    local entry found=0
    shopt -s nullglob
    for entry in "$BLS_DIR"/"$MARKER"-*.conf; do
        [[ -f "$entry" ]] || continue
        grep -Fxq "# $MARKER" "$entry" || continue
        found=1
        info "$entry"
    done
    shopt -u nullglob
    ((found == 1)) || info 'No managed Nobara ACPI test entries found.'
}

CLEANUP_PATHS=()
cleanup() {
    local path
    for path in "${CLEANUP_PATHS[@]}"; do
        [[ -n "$path" && -d "$path" ]] && rm -rf -- "$path"
    done
}
trap cleanup EXIT

(($# >= 1)) || { usage; exit 2; }
case "$1" in
    status)
        (($# == 1)) || { usage; exit 2; }
        require_nobara
        show_status
        ;;
    install)
        (($# == 3)) || { usage; exit 2; }
        [[ "$2" == 's5' || "$2" == 'combined' ]] \
            || die "Variant must be s5 or combined."
        require_root
        require_nobara
        require_commands
        check_kernel_support
        check_secure_boot
        [[ -d "$BLS_DIR" ]] || die "Nobara BLS directory is missing: $BLS_DIR"
        install_test_entry "$2" "$3"
        ;;
    remove)
        (($# <= 2)) || { usage; exit 2; }
        if (($# == 2)); then
            [[ "$2" == 's5' || "$2" == 'combined' ]] \
                || die "Variant must be s5 or combined."
        fi
        require_root
        require_nobara
        remove_entries "${2:-}"
        ;;
    *)
        usage
        exit 2
        ;;
esac
