#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

# Extracts only the decompiled DSDT source needed by this reproduction.
# Raw ACPI tables are kept in a private temporary directory and deleted on exit.

EXPECTED_PRODUCT="OMEN Gaming Laptop 16-ap0xxx"
EXPECTED_BOARD="8E35"
EXPECTED_BIOS="F.13"
MACHINE_PRODUCT=""
MACHINE_BOARD=""
MACHINE_BIOS=""
PACKAGE_FORMAT=""

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
boot_probe="$script_dir/00-probe-boot.sh"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

usage() {
    printf 'Usage: %s\n' "$0"
    printf 'Extract the local DSDT source for the OMEN ACPI reproduction.\n'
}

check_machine() {
    MACHINE_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    MACHINE_BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
    MACHINE_BIOS="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
    [[ -n "$MACHINE_PRODUCT" && -n "$MACHINE_BOARD" && -n "$MACHINE_BIOS" ]] \
        || die "DMI identity is missing, empty or unreadable"
    [[ "$MACHINE_PRODUCT$MACHINE_BOARD$MACHINE_BIOS" != *$'\n'* \
        && "$MACHINE_PRODUCT$MACHINE_BOARD$MACHINE_BIOS" != *$'\r'* ]] \
        || die "DMI identity contains an invalid line break"

    if [[ "$MACHINE_PRODUCT" == "$EXPECTED_PRODUCT" \
        && "$MACHINE_BOARD" == "$EXPECTED_BOARD" \
        && "$MACHINE_BIOS" == "$EXPECTED_BIOS" ]]; then
        PACKAGE_FORMAT=2
    else
        [[ "${OMEN_ACPI_UNVALIDATED_OPT_IN:-}" == "1" ]] \
            || die "Unvalidated machine requires the internal CLI opt-in indicator"
        PACKAGE_FORMAT=3
    fi
}

if (($# > 0)); then
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
fi

for command in sudo acpidump acpixtract iasl tar sha256sum mktemp install grep realpath awk; do
    need_cmd "$command"
done

check_machine
[[ -x "$boot_probe" ]] || die "Boot-state probe not found: $boot_probe"
sudo -- "$boot_probe" --require-stock
probe_output="$(sudo -- "$boot_probe" --env)"
original_dsdt_sha="$(awk -F= '$1 == "DSDT_SHA256" { print $2 }' <<<"$probe_output")"
[[ "$original_dsdt_sha" =~ ^[0-9a-f]{64}$ ]] \
    || die "The original DSDT fingerprint could not be recorded"

stamp="$(date +%Y%m%d-%H%M%S)"
temp_base="${TMPDIR:-/tmp}"
work="$(mktemp -d "$temp_base/omen-acpi-work.XXXXXX")"

cleanup() {
    if [[ -n "${work:-}" && -d "$work" ]]; then
        case "$(basename -- "$work")" in
            omen-acpi-work.*)
                rm -rf -- "$work"
                ;;
        esac
    fi
}
trap cleanup EXIT

raw_dir="$work/raw"
package_root="$work/package"
if [[ "$PACKAGE_FORMAT" == "2" ]]; then
    package_name="omen-ap0006sl-acpi-source-$stamp"
else
    package_name="omen-unvalidated-acpi-source-$stamp"
fi
package_dir="$package_root/$package_name"
output_dir="${OMEN_ACPI_OUTPUT_DIR:-$HOME}"
[[ -d "$output_dir" ]] || die "Output directory does not exist: $output_dir"
output_dir="$(realpath -- "$output_dir")"
archive="$output_dir/$package_name.tar.gz"

mkdir -p "$raw_dir" "$package_dir"

printf 'Dumping firmware ACPI tables into a private temporary directory...\n'
sudo acpidump > "$raw_dir/acpidump.txt"

(
    cd "$raw_dir"
    acpixtract -a acpidump.txt > acpixtract.log 2>&1
)

[[ -r "$raw_dir/dsdt.dat" ]] \
    || die "acpixtract did not produce dsdt.dat"

dumped_dsdt_sha="$(sha256sum -- "$raw_dir/dsdt.dat" | awk '{print $1}')"
[[ "$dumped_dsdt_sha" == "$original_dsdt_sha" ]] \
    || die "The DSDT emitted by acpidump does not match the verified live stock DSDT"

printf 'Decompiling the DSDT with the available SSDT namespace...\n'
(
    cd "$raw_dir"

    shopt -s nullglob
    ssdt_tables=(ssdt*.dat)
    shopt -u nullglob

    set +e
    if ((${#ssdt_tables[@]} > 0)); then
        iasl -da -dl dsdt.dat "${ssdt_tables[@]}" > decompile-all.log 2>&1
    else
        iasl -d dsdt.dat > decompile-all.log 2>&1
    fi
    decompile_status=$?
    set -e

    if [[ ! -s dsdt.dsl ]]; then
        set +e
        if ((${#ssdt_tables[@]} > 0)); then
            iasl -e "${ssdt_tables[@]}" -d dsdt.dat > decompile-dsdt.log 2>&1
        else
            iasl -d dsdt.dat > decompile-dsdt.log 2>&1
        fi
        fallback_status=$?
        set -e

        [[ "$fallback_status" -eq 0 && -s dsdt.dsl ]] \
            || die "DSDT decompilation failed; the private temporary data will be removed"
    elif [[ "$decompile_status" -ne 0 ]]; then
        printf 'Warning: full namespace decompilation returned status %s, but dsdt.dsl was produced.\n' \
            "$decompile_status" >&2
    fi
)

source_dsl="$raw_dir/dsdt.dsl"
[[ -s "$source_dsl" ]] || die "dsdt.dsl was not produced"

expected_header='DefinitionBlock ("", "DSDT", 2, "HPQOEM", "8E35    ", 0x01072009)'
expected_external='External (_SB_.PCI0.GPP0.PEGP, DeviceObj)'

[[ "$(grep -Fxc "$expected_header" "$source_dsl" || true)" -eq 1 ]] \
    || die "The original DSDT header does not match OEM revision 0x01072009"
[[ "$(grep -Fc "$expected_external" "$source_dsl" || true)" -eq 1 ]] \
    || die "The expected NVIDIA PEGP external declaration is missing or duplicated"

install -m 0600 "$source_dsl" "$package_dir/dsdt.dsl"

{
    printf 'PACKAGE_FORMAT=%s\n' "$PACKAGE_FORMAT"
    printf 'DMI_PRODUCT=%s\n' "$MACHINE_PRODUCT"
    printf 'MAINBOARD=%s\n' "$MACHINE_BOARD"
    printf 'BIOS=%s\n' "$MACHINE_BIOS"
    printf 'ORIGINAL_DSDT_OEM_REVISION=0x01072009\n'
    printf 'ORIGINAL_DSDT_SHA256=%s\n' "$original_dsdt_sha"
} > "$package_dir/SOURCE.txt"

{
    printf 'This private archive contains the decompiled DSDT source required by the next build step.\n'
    printf 'It intentionally excludes the raw acpidump, unrelated ACPI tables, system logs, kernel command line and hardware identifiers.\n'
    printf 'The DSDT is still machine-derived firmware data. Review it manually before sharing it.\n'
} > "$package_dir/README.txt"

(
    cd "$package_dir"
    sha256sum README.txt SOURCE.txt dsdt.dsl > SHA256SUMS
)

tar -czf "$archive" -C "$package_root" "$package_name"
chmod 0600 "$archive"

if [[ -n "${OMEN_ACPI_RESULT_FILE:-}" ]]; then
    printf '%s\n' "$archive" > "$OMEN_ACPI_RESULT_FILE"
    chmod 0600 "$OMEN_ACPI_RESULT_FILE"
fi

printf '\nSource archive created:\n%s\n' "$archive"
printf '\nKeep this generated archive private unless you have manually reviewed its contents.\n'
