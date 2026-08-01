#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

# Machine-readable, fail-closed detector for the ACPI state of the current boot.
# It combines the live DSDT identity with Linux's ACPI-override taint flag.

readonly EXPECTED_PRODUCT="OMEN Gaming Laptop 16-ap0xxx"
readonly EXPECTED_BOARD="8E35"
readonly EXPECTED_BIOS="F.13"
readonly EXPECTED_OEM_ID="HPQOEM"
readonly EXPECTED_TABLE_ID="8E35    "
readonly ORIGINAL_REVISION="0x01072009"
readonly S5_REVISION="0x0107200A"
readonly COMBINED_REVISION="0x0107200B"
readonly ACPI_OVERRIDE_TAINT=256

mode="env"

usage() {
    cat <<'EOF'
Usage: 00-probe-boot.sh [--env|--human|--require-stock]

Inspect the current boot and classify its active ACPI table state. The probe
must run as root because the live DSDT is normally root-readable only.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

root_path() {
    local path="$1"
    if [[ "${OMEN_ACPI_TESTING:-0}" == "1" ]]; then
        printf '%s%s\n' "${OMEN_ACPI_TEST_ROOT:?OMEN_ACPI_TEST_ROOT is required in test mode}" "$path"
    else
        printf '%s\n' "$path"
    fi
}

read_text() {
    local path
    path="$(root_path "$1")"
    [[ -r "$path" ]] || return 1
    tr -d '\r\n' < "$path"
}

for argument in "$@"; do
    case "$argument" in
        --env)
            mode="env"
            ;;
        --human)
            mode="human"
            ;;
        --require-stock)
            mode="require-stock"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $argument"
            ;;
    esac
done

if [[ "${OMEN_ACPI_TESTING:-0}" != "1" && EUID -ne 0 ]]; then
    die "This probe must run as root."
fi

for command in awk grep python3 sha256sum tr; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

product="$(read_text /sys/class/dmi/id/product_name 2>/dev/null || true)"
board="$(read_text /sys/class/dmi/id/board_name 2>/dev/null || true)"
bios="$(read_text /sys/class/dmi/id/bios_version 2>/dev/null || true)"

machine_ok=0
if [[ "$product" == "$EXPECTED_PRODUCT" \
    && "$board" == "$EXPECTED_BOARD" \
    && "$bios" == "$EXPECTED_BIOS" ]]; then
    machine_ok=1
fi

dsdt_path="$(root_path /sys/firmware/acpi/tables/DSDT)"
dsdt_readable=0
dsdt_identity_ok=0
dsdt_revision="unavailable"
dsdt_sha256="unavailable"

if [[ -r "$dsdt_path" ]]; then
    dsdt_readable=1
    dsdt_sha256="$(sha256sum -- "$dsdt_path" | awk '{print $1}')"
    mapfile -t dsdt_fields < <(
        python3 - "$dsdt_path" "$EXPECTED_OEM_ID" "$EXPECTED_TABLE_ID" <<'PY'
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
expected_oem = sys.argv[2]
expected_table = sys.argv[3]
data = path.read_bytes()

if len(data) < 36:
    print("unavailable")
    print("0")
    raise SystemExit(0)

signature = data[0:4]
length = struct.unpack_from("<I", data, 4)[0]
oem_id = data[10:16].decode("ascii", "replace")
table_id = data[16:24].decode("ascii", "replace")
revision = struct.unpack_from("<I", data, 24)[0]
identity_ok = (
    signature == b"DSDT"
    and length == len(data)
    and sum(data) & 0xFF == 0
    and oem_id == expected_oem
    and table_id == expected_table
)

print(f"0x{revision:08X}")
print("1" if identity_ok else "0")
PY
    )
    dsdt_revision="${dsdt_fields[0]:-unavailable}"
    dsdt_identity_ok="${dsdt_fields[1]:-0}"
fi

taint_path="$(root_path /proc/sys/kernel/tainted)"
taint_value="unavailable"
taint_acpi="unknown"
if [[ -r "$taint_path" ]]; then
    taint_value="$(tr -d '[:space:]' < "$taint_path")"
    if [[ "$taint_value" =~ ^[0-9]+$ ]]; then
        if (( (taint_value & ACPI_OVERRIDE_TAINT) != 0 )); then
            taint_acpi=1
        else
            taint_acpi=0
        fi
    fi
fi

log_early_acpi=0
log_override="unknown"
log_dsdt_override="unknown"
log_other_acpi="unknown"
log_candidate="unknown"
kernel_log=""
if [[ "${OMEN_ACPI_TESTING:-0}" == "1" ]]; then
    test_log="${OMEN_ACPI_TEST_DMESG_FILE:-}"
    if [[ -n "$test_log" && -r "$test_log" ]]; then
        kernel_log="$(<"$test_log")"
    fi
else
    journal_log=""
    dmesg_log=""
    if command -v journalctl >/dev/null 2>&1; then
        journal_log="$(journalctl -k -b -o cat --no-pager 2>/dev/null || true)"
    fi
    dmesg_log="$(dmesg 2>/dev/null || true)"
    kernel_log="${journal_log}${journal_log:+$'\n'}${dmesg_log}"
fi

# A zero exit status from journalctl does not prove that the early boot log is
# complete.  Only a recognisable early ACPI table-discovery line makes a
# negative result usable.  Positive override evidence is authoritative even
# when the rest of the log is incomplete.
if [[ -n "$kernel_log" ]] \
    && grep -Eiq \
        'ACPI:[[:space:]]+((RSDP|XSDT|RSDT|DSDT)[[:space:]]|Early table checksum verification)' \
        <<<"$kernel_log"; then
    log_early_acpi=1
    log_override=0
    log_dsdt_override=0
    log_other_acpi=0
    log_candidate=0
fi

if [[ -n "$kernel_log" ]]; then
    candidate_lines="$(
        grep -Ei \
            'ACPI:[[:space:]]+[[:alnum:]_]{4}[[:space:]]+ACPI table found in initrd' \
            <<<"$kernel_log" || true
    )"
    upgrade_lines="$(
        grep -Ei \
            'ACPI:.*Table Upgrade: (install|override) \[[[:alnum:]_]{4}-' \
            <<<"$kernel_log" || true
    )"
    physical_lines="$(
        grep -Ei \
            'ACPI:[[:space:]]+[[:alnum:]_]{4}[[:space:]].*Physical table override, new table:' \
            <<<"$kernel_log" || true
    )"
    builtin_lines="$(
        grep -Ei \
            'ACPI:.*Override \[[[:alnum:]_]{4}-.*unsafe: tainting kernel' \
            <<<"$kernel_log" || true
    )"

    if [[ -n "$candidate_lines" ]]; then
        log_candidate=1
    fi

    accepted_lines=""
    for evidence_lines in "$upgrade_lines" "$physical_lines" "$builtin_lines"; do
        if [[ -n "$evidence_lines" ]]; then
            accepted_lines+="${accepted_lines:+$'\n'}${evidence_lines}"
        fi
    done
    if [[ -n "$accepted_lines" ]]; then
        log_override=1
        if grep -Eiq \
            '(\[DSDT-|ACPI:[[:space:]]+DSDT[[:space:]].*Physical table override)' \
            <<<"$accepted_lines"; then
            log_dsdt_override=1
        fi
        if grep -Eivq \
            '(\[DSDT-|ACPI:[[:space:]]+DSDT[[:space:]].*Physical table override)' \
            <<<"$accepted_lines"; then
            log_other_acpi=1
        fi
    fi
fi

validated_managed_hash() {
    local state_path="$1" expected_variant="$2" expected_revision="$3"
    local aml checksum_file variant_file revision_file stored_hash actual_hash

    aml="$state_path/DSDT.aml"
    checksum_file="$state_path/DSDT.sha256"
    variant_file="$state_path/variant.txt"
    revision_file="$state_path/expected-revision.txt"
    [[ -d "$state_path" && ! -L "$state_path" ]] || return 1
    for file in "$aml" "$checksum_file" "$variant_file" "$revision_file"; do
        [[ -f "$file" && ! -L "$file" ]] || return 1
    done
    [[ "$(tr -d '\r\n' < "$variant_file")" == "$expected_variant" ]] || return 1
    [[ "$(tr -d '\r\n' < "$revision_file")" == "$expected_revision" ]] || return 1
    stored_hash="$(tr -d '[:space:]' < "$checksum_file")"
    [[ "$stored_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_hash="$(sha256sum -- "$aml" | awk '{print $1}')"
    [[ "$actual_hash" == "$stored_hash" ]] || return 1
    python3 - "$aml" "$expected_revision" "$EXPECTED_OEM_ID" "$EXPECTED_TABLE_ID" <<'PY'
from pathlib import Path
import struct
import sys

data = Path(sys.argv[1]).read_bytes()
expected_revision = int(sys.argv[2], 0)
expected_oem = sys.argv[3]
expected_table = sys.argv[4]
if len(data) < 36:
    raise SystemExit(1)
if data[:4] != b"DSDT" or struct.unpack_from("<I", data, 4)[0] != len(data):
    raise SystemExit(1)
if sum(data) & 0xFF:
    raise SystemExit(1)
if data[10:16].decode("ascii", "strict") != expected_oem:
    raise SystemExit(1)
if data[16:24].decode("ascii", "strict") != expected_table:
    raise SystemExit(1)
if struct.unpack_from("<I", data, 24)[0] != expected_revision:
    raise SystemExit(1)
PY
    printf '%s\n' "$actual_hash"
}

validated_legacy_hash() {
    local state_path="$1" expected_variant="$2" expected_revision="$3"

    python3 - \
        "$state_path" \
        "$expected_variant" \
        "$expected_revision" \
        "$EXPECTED_OEM_ID" \
        "$EXPECTED_TABLE_ID" <<'PY'
from pathlib import Path
import hashlib
import os
import re
import struct
import sys

state = Path(sys.argv[1])
variant = sys.argv[2]
expected_revision = int(sys.argv[3], 0)
expected_oem = sys.argv[4].encode("ascii")
expected_table = sys.argv[5].encode("ascii")

if variant == "s5":
    state_aml_name = "DSDT-S5-test.aml"
    manifest_aml_name = "DSDT-OMEN-F13-S5-test.aml"
    source_dsl_name = "DSDT-OMEN-F13-S5-test.dsl"
    initramfs_name = "initramfs-omen-acpi-s5-test.img"
elif variant == "combined":
    state_aml_name = "DSDT-combined-test.aml"
    manifest_aml_name = "DSDT-OMEN-F13-combined-test.aml"
    source_dsl_name = "DSDT-OMEN-F13-combined-test.dsl"
    initramfs_name = "initramfs-omen-acpi-combined-test.img"
else:
    raise SystemExit(1)

required_names = {
    state_aml_name,
    source_dsl_name,
    "SHA256SUMS",
    "compile.log",
    "kernel-version.txt",
    "limine.conf.before",
    "source-archive.txt",
    "source-entry.txt",
}
allowed_names = required_names | {"dropin.before"}

if not state.is_dir() or state.is_symlink():
    raise SystemExit(1)
try:
    state_metadata = state.stat()
    entries = list(state.iterdir())
except OSError:
    raise SystemExit(1)
if state_metadata.st_uid != os.geteuid() or state_metadata.st_mode & 0o022:
    raise SystemExit(1)
entry_names = {entry.name for entry in entries}
if not required_names.issubset(entry_names) or not entry_names.issubset(allowed_names):
    raise SystemExit(1)
if len(entry_names) != len(entries):
    raise SystemExit(1)
for entry in entries:
    if entry.is_symlink() or not entry.is_file():
        raise SystemExit(1)
    try:
        metadata = entry.stat()
    except OSError:
        raise SystemExit(1)
    if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
        raise SystemExit(1)

source_archive_path = state / "source-archive.txt"
try:
    if source_archive_path.stat().st_size > 16 * 1024:
        raise SystemExit(1)
    source_lines = source_archive_path.read_text(
        encoding="utf-8", errors="strict"
    ).splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
if len(source_lines) != 1 or not source_lines[0] or "\x00" in source_lines[0]:
    raise SystemExit(1)
source_archive = Path(source_lines[0])
if not source_archive.is_absolute():
    raise SystemExit(1)

manifest_path = state / "SHA256SUMS"
try:
    if manifest_path.stat().st_size > 64 * 1024:
        raise SystemExit(1)
    manifest_lines = manifest_path.read_text(
        encoding="utf-8", errors="strict"
    ).splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
if len(manifest_lines) != 3:
    raise SystemExit(1)

manifest = {}
manifest_names = []
for line in manifest_lines:
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
    if match is None:
        raise SystemExit(1)
    digest, raw_name = match.groups()
    if raw_name in manifest or "\x00" in raw_name:
        raise SystemExit(1)
    path = Path(raw_name)
    if not path.is_absolute():
        raise SystemExit(1)
    manifest[raw_name] = digest
    manifest_names.append(raw_name)

archive_name, aml_name, initramfs_manifest_name = manifest_names
aml_manifest_path = Path(aml_name)
initramfs_manifest_path = Path(initramfs_manifest_name)
legacy_root_pattern = (
    r"omen-s5-test\.[A-Za-z0-9]{6}"
    if variant == "s5"
    else r"omen-combined-test\.[A-Za-z0-9]{6}"
)
if archive_name != str(source_archive):
    raise SystemExit(1)
if aml_manifest_path.name != manifest_aml_name:
    raise SystemExit(1)
if initramfs_manifest_path.name != initramfs_name:
    raise SystemExit(1)
if aml_manifest_path.parent.name != "build":
    raise SystemExit(1)
legacy_root = aml_manifest_path.parent.parent
if not re.fullmatch(legacy_root_pattern, legacy_root.name):
    raise SystemExit(1)
if legacy_root.parent != Path("/var/tmp"):
    raise SystemExit(1)
if initramfs_manifest_path.parent != legacy_root:
    raise SystemExit(1)

aml_path = state / state_aml_name
try:
    aml_size = aml_path.stat().st_size
    if aml_size < 36 or aml_size > 16 * 1024 * 1024:
        raise SystemExit(1)
    data = aml_path.read_bytes()
except OSError:
    raise SystemExit(1)
if len(data) != aml_size:
    raise SystemExit(1)
if data[:4] != b"DSDT" or struct.unpack_from("<I", data, 4)[0] != len(data):
    raise SystemExit(1)
if sum(data) & 0xFF:
    raise SystemExit(1)
if data[10:16] != expected_oem or data[16:24] != expected_table:
    raise SystemExit(1)
if struct.unpack_from("<I", data, 24)[0] != expected_revision:
    raise SystemExit(1)

actual_hash = hashlib.sha256(data).hexdigest()
if manifest[aml_name] != actual_hash:
    raise SystemExit(1)
print(actual_hash)
PY
}

managed_s5_state="$(root_path /var/lib/omen-acpi-s5-test)"
managed_combined_state="$(root_path /var/lib/omen-acpi-combined-test)"
managed_s5_sha="$(validated_managed_hash "$managed_s5_state" s5 "$S5_REVISION" 2>/dev/null || true)"
managed_combined_sha="$(validated_managed_hash "$managed_combined_state" combined "$COMBINED_REVISION" 2>/dev/null || true)"
legacy_s5_sha="$(validated_legacy_hash "$managed_s5_state" s5 "$S5_REVISION" 2>/dev/null || true)"
legacy_combined_sha="$(validated_legacy_hash "$managed_combined_state" combined "$COMBINED_REVISION" 2>/dev/null || true)"

s5_format="absent"
combined_format="absent"
if [[ -n "$managed_s5_sha" ]]; then
    s5_format="managed"
elif [[ -n "$legacy_s5_sha" ]]; then
    s5_format="legacy"
elif [[ -e "$managed_s5_state" || -L "$managed_s5_state" ]]; then
    s5_format="conflict"
fi
if [[ -n "$managed_combined_sha" ]]; then
    combined_format="managed"
elif [[ -n "$legacy_combined_sha" ]]; then
    combined_format="legacy"
elif [[ -e "$managed_combined_state" || -L "$managed_combined_state" ]]; then
    combined_format="conflict"
fi

active_format="none"
if [[ -n "$managed_s5_sha" && "$dsdt_sha256" == "$managed_s5_sha" ]] \
    || [[ -n "$managed_combined_sha" && "$dsdt_sha256" == "$managed_combined_sha" ]]; then
    active_format="managed"
elif [[ -n "$legacy_s5_sha" && "$dsdt_sha256" == "$legacy_s5_sha" ]] \
    || [[ -n "$legacy_combined_sha" && "$dsdt_sha256" == "$legacy_combined_sha" ]]; then
    active_format="legacy"
fi

boot_marker="none"
boot_marker_count=0
cmdline_path="$(root_path /proc/cmdline)"
if [[ -r "$cmdline_path" ]]; then
    read -r -a cmdline_parameters < "$cmdline_path" || true
    for parameter in "${cmdline_parameters[@]:-}"; do
        case "$parameter" in
            omen_acpi.variant=s5)
                ((boot_marker_count += 1))
                boot_marker="s5"
                ;;
            omen_acpi.variant=combined)
                ((boot_marker_count += 1))
                boot_marker="combined"
                ;;
            omen_acpi.variant=*)
                ((boot_marker_count += 1))
                boot_marker="invalid"
                ;;
        esac
    done
fi
if (( boot_marker_count > 1 )); then
    boot_marker="invalid"
fi

state="unavailable"
reason="probe-incomplete"
clean=0

if (( ! machine_ok )); then
    state="unsupported"
    reason="machine-mismatch"
elif (( ! dsdt_readable )); then
    state="unavailable"
    reason="live-state-unreadable"
elif [[ "$boot_marker" == "invalid" ]]; then
    state="unknown"
    reason="invalid-or-duplicate-boot-marker"
elif [[ -n "$managed_s5_sha" && "$dsdt_sha256" == "$managed_s5_sha" \
    && "$dsdt_revision" == "$S5_REVISION" \
    && "$boot_marker" != "combined" ]]; then
    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then
        state="unknown"
        reason="additional-acpi-override"
    else
        state="s5"
        reason="managed-s5-hash"
    fi
elif [[ -n "$managed_combined_sha" && "$dsdt_sha256" == "$managed_combined_sha" \
    && "$dsdt_revision" == "$COMBINED_REVISION" \
    && "$boot_marker" != "s5" ]]; then
    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then
        state="unknown"
        reason="additional-acpi-override"
    else
        state="combined"
        reason="managed-combined-hash"
    fi
elif [[ -n "$legacy_s5_sha" && "$dsdt_sha256" == "$legacy_s5_sha" \
    && "$dsdt_revision" == "$S5_REVISION" \
    && "$boot_marker" == "none" ]]; then
    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then
        state="unknown"
        reason="additional-acpi-override"
    else
        state="s5"
        reason="legacy-s5-hash"
    fi
elif [[ -n "$legacy_combined_sha" && "$dsdt_sha256" == "$legacy_combined_sha" \
    && "$dsdt_revision" == "$COMBINED_REVISION" \
    && "$boot_marker" == "none" ]]; then
    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then
        state="unknown"
        reason="additional-acpi-override"
    else
        state="combined"
        reason="legacy-combined-hash"
    fi
elif [[ "$taint_acpi" == "0" && "$log_override" == "0" \
    && "$boot_marker" == "none" && "$dsdt_identity_ok" == "1" \
    && "$dsdt_revision" == "$ORIGINAL_REVISION" ]]; then
    state="stock"
    reason="stock-signals-consistent"
    clean=1
elif [[ "$taint_acpi" == "1" || "$log_override" == "1" \
    || "$boot_marker" != "none" || "$dsdt_identity_ok" != "1" \
    || "$dsdt_revision" != "$ORIGINAL_REVISION" ]]; then
    state="unknown"
    reason="acpi-state-disagreement"
elif [[ "$taint_acpi" == "unknown" || "$log_override" == "unknown" ]]; then
    state="unavailable"
    reason="override-signals-unreadable"
else
    state="unknown"
    reason="acpi-state-disagreement"
fi

emit_env() {
    printf 'STATE=%s\n' "$state"
    printf 'CLEAN=%s\n' "$clean"
    printf 'REASON=%s\n' "$reason"
    printf 'MACHINE_OK=%s\n' "$machine_ok"
    printf 'DSDT_READABLE=%s\n' "$dsdt_readable"
    printf 'DSDT_IDENTITY_OK=%s\n' "$dsdt_identity_ok"
    printf 'DSDT_REVISION=%s\n' "$dsdt_revision"
    printf 'DSDT_SHA256=%s\n' "$dsdt_sha256"
    printf 'TAINT_VALUE=%s\n' "$taint_value"
    printf 'TAINT_ACPI=%s\n' "$taint_acpi"
    printf 'LOG_EARLY_ACPI=%s\n' "$log_early_acpi"
    printf 'LOG_OVERRIDE=%s\n' "$log_override"
    printf 'LOG_DSDT_OVERRIDE=%s\n' "$log_dsdt_override"
    printf 'LOG_OTHER_ACPI=%s\n' "$log_other_acpi"
    printf 'LOG_CANDIDATE=%s\n' "$log_candidate"
    printf 'BOOT_MARKER=%s\n' "$boot_marker"
    printf 'S5_FORMAT=%s\n' "$s5_format"
    printf 'COMBINED_FORMAT=%s\n' "$combined_format"
    printf 'ACTIVE_FORMAT=%s\n' "$active_format"
}

emit_human() {
    printf 'Machine match: %s\n' "$([[ "$machine_ok" == "1" ]] && printf yes || printf no)"
    printf 'Boot state: %s\n' "$state"
    printf 'Active DSDT revision: %s\n' "$dsdt_revision"
    printf 'ACPI override taint: %s\n' "$taint_acpi"
    printf 'Kernel-log override evidence: %s\n' "$log_override"
    printf 'Kernel-log non-DSDT override evidence: %s\n' "$log_other_acpi"
    printf 'Limine variant marker: %s\n' "$boot_marker"
    printf 'S5 managed-state format: %s\n' "$s5_format"
    printf 'Combined managed-state format: %s\n' "$combined_format"
    printf 'Active matched-state format: %s\n' "$active_format"
    printf 'Classification reason: %s\n' "$reason"
}

case "$mode" in
    env)
        emit_env
        ;;
    human)
        emit_human
        ;;
    require-stock)
        if [[ "$clean" == "1" ]]; then
            printf 'Stock boot confirmed: original DSDT revision %s is active.\n' "$ORIGINAL_REVISION"
        else
            emit_human >&2
            printf '\nBLOCKED: a clean stock boot could not be proven.\n' >&2
            printf 'Reboot and select the normal CachyOS entry in Limine, then try again.\n' >&2
            exit 4
        fi
        ;;
esac
