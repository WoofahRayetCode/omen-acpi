#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Read-only Nobara preflight and post-boot verification for the OMEN ACPI test.
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly BOOT_DIR="/boot"
readonly BLS_DIR="$BOOT_DIR/loader/entries"
readonly STATE_DIR="$BOOT_DIR/omen-acpi-nobara"
readonly MARKER="omen-acpi-nobara-test"

PASS=0
WARN=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf 'WARN  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME preflight
  $SCRIPT_NAME verify [s5|combined]

preflight is run before installing the test entry. verify is run after booting
the separate Nobara OMEN ACPI test entry.
EOF
}

require_nobara() {
    if [[ ! -r /etc/os-release ]]; then
        fail '/etc/os-release is missing.'
        return
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == 'nobara' ]] \
        && pass "Nobara detected (${PRETTY_NAME:-Nobara})" \
        || fail "Expected Nobara, detected ID=${ID:-unknown}."
}

check_command() {
    local command="$1"
    command -v "$command" >/dev/null 2>&1 \
        && pass "Command available: $command" \
        || fail "Command missing: $command"
}

check_secure_boot() {
    if ! command -v mokutil >/dev/null 2>&1; then
        warn 'mokutil is unavailable; Secure Boot state could not be checked.'
    elif mokutil --sb-state 2>/dev/null | grep -qi '^SecureBoot enabled'; then
        fail 'Secure Boot is enabled; ACPI table overrides may be blocked.'
    else
        pass 'Secure Boot is disabled.'
    fi
}

check_kernel() {
    local kernel config
    kernel="$(uname -r)"
    config="$BOOT_DIR/config-$kernel"
    [[ -r "$config" ]] \
        && pass "Kernel configuration found: $config" \
        || { fail "Kernel configuration missing: $config"; return; }
    grep -Fxq 'CONFIG_ACPI_TABLE_UPGRADE=y' "$config" \
        && pass 'CONFIG_ACPI_TABLE_UPGRADE=y' \
        || fail 'CONFIG_ACPI_TABLE_UPGRADE=y is not enabled.'
    [[ -f "$BOOT_DIR/vmlinuz-$kernel" ]] \
        && pass "Kernel image found: /boot/vmlinuz-$kernel" \
        || fail "Kernel image missing: /boot/vmlinuz-$kernel"
}

find_initramfs() {
    local kernel="$1" candidate
    for candidate in \
        "$BOOT_DIR/initramfs-$kernel.img" \
        "$BOOT_DIR/initramfs-$kernel.img.zst" \
        "$BOOT_DIR/initramfs-$kernel.img.xz"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

check_boot_layout() {
    local kernel initramfs entries
    kernel="$(uname -r)"
    if initramfs="$(find_initramfs "$kernel")"; then
        pass "Initramfs found: $initramfs"
    else
        fail "No initramfs found for the running kernel: $kernel"
    fi
    if [[ -d "$BLS_DIR" ]]; then
        entries="$(find "$BLS_DIR" -maxdepth 1 -type f -name '*.conf' | wc -l)"
        ((entries > 0)) && pass "GRUB BLS entries found: $entries" \
            || fail "No GRUB BLS entries found in $BLS_DIR"
        if compgen -G "$BLS_DIR/$MARKER-*.conf" >/dev/null; then
            pass 'Managed Nobara ACPI test entry exists.'
        else
            warn 'No managed Nobara ACPI test entry exists yet.'
        fi
    else
        fail "GRUB BLS directory missing: $BLS_DIR"
    fi
}

check_tools() {
    local command
    for command in cpio iasl sha256sum tar; do
        check_command "$command"
    done
}

check_gpu() {
    local gpu_lines
    if ! command -v lspci >/dev/null 2>&1; then
        warn 'lspci is unavailable; GPU PCI state could not be checked.'
    else
        gpu_lines="$(lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
        [[ -n "$gpu_lines" ]] \
            && pass "GPU detected: ${gpu_lines//$'\n'/; }" \
            || fail 'No display controller was reported by lspci.'
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null; then
            pass 'NVIDIA driver responds to nvidia-smi.'
        else
            warn 'nvidia-smi exists but did not return GPU information.'
        fi
    else
        warn 'nvidia-smi is unavailable; NVIDIA driver state was not verified.'
    fi
}

check_stock_initramfs() {
    local kernel initramfs listing
    kernel="$(uname -r)"
    initramfs="$(find_initramfs "$kernel" 2>/dev/null || true)"
    [[ -n "$initramfs" ]] || return 0
    if ! command -v lsinitrd >/dev/null 2>&1; then
        warn 'lsinitrd is unavailable; stock initramfs contents were not inspected.'
        return 0
    fi
    listing="$(lsinitrd "$initramfs" 2>/dev/null || true)"
    if grep -q 'kernel/firmware/acpi/' <<<"$listing"; then
        warn "The current initramfs contains ACPI files; confirm it is not already patched: $initramfs"
    else
        pass 'Current initramfs has no visible ACPI override payload.'
    fi
}

current_dsdt_hash() {
    [[ -r /sys/firmware/acpi/tables/DSDT ]] \
        && sha256sum /sys/firmware/acpi/tables/DSDT | awk '{print $1}' \
        || return 1
}

verify_override() {
    local variant="${1:-}" log_text expected_hash actual_hash state_hash
    log_text="$(journalctl -k -b --no-pager 2>/dev/null || true)"
    if grep -Eiq 'ACPI.*(Table Upgrade|OVERRIDE).*DSDT|DSDT.*(override|upgrade)' <<<"$log_text"; then
        pass 'Kernel log reports an ACPI DSDT override/upgrade.'
    else
        fail 'Kernel log does not report an ACPI DSDT override/upgrade.'
    fi

    if actual_hash="$(current_dsdt_hash)"; then
        pass "Active DSDT SHA-256: $actual_hash"
    else
        fail 'Active DSDT could not be read from /sys/firmware/acpi/tables/DSDT.'
        actual_hash=''
    fi

    if [[ -n "$variant" ]]; then
        state_hash="$STATE_DIR/$variant/$(uname -r)/DSDT.sha256"
        if [[ -r "$state_hash" ]]; then
            expected_hash="$(awk '{print $1}' "$state_hash")"
            [[ -n "$actual_hash" && "$actual_hash" == "$expected_hash" ]] \
                && pass "Active DSDT matches the $variant build hash." \
                || fail "Active DSDT does not match the recorded $variant build hash."
        else
            warn "No recorded DSDT hash for variant $variant; only log evidence was checked."
        fi
    fi

    check_gpu
    local pci_device=''
    pci_device="$(lspci -Dn 2>/dev/null | awk '/NVIDIA.*(VGA|3D|Display)/ {print $1; exit}' || true)"
    if [[ -n "$pci_device" && -r "/sys/bus/pci/devices/$pci_device/power/runtime_status" ]]; then
        pass "NVIDIA runtime power state: $(<"/sys/bus/pci/devices/$pci_device/power/runtime_status")"
    else
        warn 'NVIDIA runtime power state could not be read.'
    fi
    warn 'A real orderly shutdown and cold-boot comparison is still required to prove the S5 power-down result.'
}

print_summary() {
    printf '\nSummary: %d passed, %d warnings, %d failures.\n' "$PASS" "$WARN" "$FAIL"
    ((FAIL == 0))
}

(($# >= 1 && $# <= 2)) || { usage; exit 2; }
case "$1" in
    preflight)
        (($# == 1)) || { usage; exit 2; }
        require_nobara
        check_tools
        check_secure_boot
        check_kernel
        check_boot_layout
        check_stock_initramfs
        check_gpu
        ;;
    verify)
        (($# == 1 || $# == 2)) || { usage; exit 2; }
        require_nobara
        verify_override "${2:-}"
        ;;
    *)
        usage
        exit 2
        ;;
esac
print_summary
