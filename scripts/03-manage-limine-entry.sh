#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

# Manage separate S5-only and combined Limine entries for the reference or an
# explicitly opted-in machine. The normal CachyOS entry is never replaced.

readonly VERSION="2.5.0"
readonly LOCK_DIRECTORY="/run/omen-acpi-fix"
readonly LOCK_FILE="$LOCK_DIRECTORY/manager.lock"
readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BOOT_PROBE="$SCRIPT_DIR/00-probe-boot.sh"
readonly KERNEL_ENTRIES="$SCRIPT_DIR/05-kernel-entries.py"

readonly EXPECTED_PRODUCT="OMEN Gaming Laptop 16-ap0xxx"
readonly EXPECTED_BOARD="8E35"
readonly EXPECTED_BIOS="F.13"
readonly EXPECTED_NVIDIA_BDF="0000:01:00.0"
readonly EXPECTED_ORIGINAL_REVISION="0x01072009"

VARIANT=""
ENTRY_NAME=""
DROPIN=""
STATE_DIR=""
EXPECTED_PATCHED_REVISION=""
LEGACY_AML_NAME=""
LEGACY_DSL_NAME=""
LEGACY_BUILD_AML_NAME=""
LEGACY_DROPIN_COMMENT=""
LEGACY_ENTRY_COMMENT=""
LEGACY_TEMP_PREFIX=""
LEGACY_COMPOSITE_NAME=""

NORMAL_TITLE=""
NORMAL_KERNEL_LIMINE=""
NORMAL_KERNEL_LOCAL=""
NORMAL_CMDLINE=""
declare -a NORMAL_MODULES_LIMINE=()
declare -a NORMAL_MODULES_LOCAL=()
BUILT_AML=""
ORIGINAL_DSDT_SHA256=""
LEGACY_BACKUP=""
MANAGED_RECOVERY=""
MACHINE_PRODUCT=""
MACHINE_BOARD=""
MACHINE_BIOS=""
PACKAGE_FORMAT=""

# EXIT traps run after action-local variables have left scope.  Keep cleanup
# state global so a fail-closed exit can remove staging safely without tripping
# `set -u` or losing the paths it must handle.
ACTION_CLEANUP_WORK=""
ACTION_CLEANUP_CANDIDATE=""
ACTION_CLEANUP_PRESERVE_CANDIDATE=0

# Output and command selection

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
HP OMEN 16-ap0xxx BIOS F.13 ACPI override manager

Usage:
  03-manage-limine-entry.sh install VARIANT BUILD_ARCHIVE
  03-manage-limine-entry.sh refresh VARIANT
  03-manage-limine-entry.sh status VARIANT
  03-manage-limine-entry.sh inspect VARIANT
  03-manage-limine-entry.sh remove VARIANT
  03-manage-limine-entry.sh stock-entry
  03-manage-limine-entry.sh pre-uninstall-check
  03-manage-limine-entry.sh help

VARIANT must be one of:
  s5        S5 power-off correction only
  combined  S5 power-off correction plus the two confirmed BF01 loop bounds

Actions:
  install   Build and install a separate experimental Limine entry. An explicit
            build archive is required.
  refresh   Reconcile the installed variant with every supported CachyOS kernel.
  status    Report the running kernel and per-kernel entry state.
  remove    Remove only the entry and files owned by this manager.
  stock-entry
            Print the exact normal CachyOS Limine entry selected by the safe
            parser. This read-only action is used by the public CLI.
  pre-uninstall-check
            Prove that neither a reserved entry name nor an orphaned stock
            recovery payload remains on the mounted ESP before uninstall.

No action is taken when the script is run without an explicit action.
EOF
}

select_variant() {
    VARIANT="$1"
    case "$VARIANT" in
        s5)
            ENTRY_NAME="zz-omen-acpi-s5-test"
            DROPIN="/etc/limine-entry-tool.d/90-omen-acpi-s5-test.conf"
            STATE_DIR="/var/lib/omen-acpi-s5-test"
            EXPECTED_PATCHED_REVISION="0x0107200A"
            LEGACY_AML_NAME="DSDT-S5-test.aml"
            LEGACY_DSL_NAME="DSDT-OMEN-F13-S5-test.dsl"
            LEGACY_BUILD_AML_NAME="DSDT-OMEN-F13-S5-test.aml"
            LEGACY_DROPIN_COMMENT="# Creato da install-omen-s5-limine-test.sh"
            LEGACY_ENTRY_COMMENT="SPERIMENTALE: HP OMEN F.13 DSDT S5; voce normale invariata"
            LEGACY_TEMP_PREFIX="omen-s5-test"
            LEGACY_COMPOSITE_NAME="initramfs-omen-acpi-s5-test.img"
            ;;
        combined)
            ENTRY_NAME="zz-omen-acpi-combined-test"
            DROPIN="/etc/limine-entry-tool.d/91-omen-acpi-combined-test.conf"
            STATE_DIR="/var/lib/omen-acpi-combined-test"
            EXPECTED_PATCHED_REVISION="0x0107200B"
            LEGACY_AML_NAME="DSDT-combined-test.aml"
            LEGACY_DSL_NAME="DSDT-OMEN-F13-combined-test.dsl"
            LEGACY_BUILD_AML_NAME="DSDT-OMEN-F13-combined-test.aml"
            LEGACY_DROPIN_COMMENT="# Creato da install-omen-combined-limine-test.sh"
            LEGACY_ENTRY_COMMENT="SPERIMENTALE: HP OMEN F.13 DSDT S5 + WQBZ; voce normale invariata"
            LEGACY_TEMP_PREFIX="omen-combined-test"
            LEGACY_COMPOSITE_NAME="initramfs-omen-acpi-combined-test.img"
            ;;
        *)
            die "Unknown variant '$VARIANT'. Expected 's5' or 'combined'."
            ;;
    esac
}

# Privilege, locking and machine preconditions

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

absolute_existing_file() {
    local path="$1"
    [[ -f "$path" ]] || die "File not found: $path"
    realpath -- "$path"
}

require_root() {
    if (( EUID != 0 )); then
        local self
        need_cmd sudo
        need_cmd realpath
        self="$(realpath -- "$0")"
        exec sudo -- "$self" "$@"
    fi
}

acquire_lock() {
    local inherited_target lock_owner lock_mode

    if [[ "${OMEN_ACPI_LOCK_FD9_HELD:-0}" == "1" ]]; then
        inherited_target="$(readlink -f /proc/self/fd/9 2>/dev/null || true)"
        [[ "$inherited_target" == "$LOCK_FILE" ]] \
            || die "The inherited installation lock descriptor is invalid."
        flock -n 9 \
            || die "The inherited installation lock is not held."
        return 0
    fi

    [[ -d /run && ! -L /run && "$(stat -c '%u' -- /run)" == "0" ]] \
        || die "The runtime directory is unavailable or unsafe: /run"
    if [[ ! -e "$LOCK_DIRECTORY" && ! -L "$LOCK_DIRECTORY" ]]; then
        install -d -o root -g root -m 0700 "$LOCK_DIRECTORY"
    fi
    [[ -d "$LOCK_DIRECTORY" && ! -L "$LOCK_DIRECTORY" ]] \
        || die "The toolkit lock directory is unavailable or unsafe: $LOCK_DIRECTORY"
    lock_owner="$(stat -c '%u' -- "$LOCK_DIRECTORY")"
    lock_mode="$(stat -c '%a' -- "$LOCK_DIRECTORY")"
    [[ "$lock_owner" == "0" && "$lock_mode" == "700" ]] \
        || die "The toolkit lock directory must be root-owned with mode 0700: $LOCK_DIRECTORY"
    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" \
            && "$(stat -c '%u' -- "$LOCK_FILE")" == "0" ]] \
            || die "The toolkit lock file is unsafe: $LOCK_FILE"
    fi
    exec 9>>"$LOCK_FILE"
    flock -x 9 || die "Could not acquire the installation lock: $LOCK_FILE"
}

read_machine() {
    MACHINE_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    MACHINE_BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
    MACHINE_BIOS="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
    [[ -n "$MACHINE_PRODUCT" && -n "$MACHINE_BOARD" && -n "$MACHINE_BIOS" ]] \
        || die "DMI identity is missing, empty or unreadable"
    [[ "$MACHINE_PRODUCT$MACHINE_BOARD$MACHINE_BIOS" != *$'\n'* \
        && "$MACHINE_PRODUCT$MACHINE_BOARD$MACHINE_BIOS" != *$'\r'* ]] \
        || die "DMI identity contains an invalid line break"
}

machine_is_reference() {
    [[ "$MACHINE_PRODUCT" == "$EXPECTED_PRODUCT" \
        && "$MACHINE_BOARD" == "$EXPECTED_BOARD" \
        && "$MACHINE_BIOS" == "$EXPECTED_BIOS" ]]
}

check_machine() {
    read_machine
    if machine_is_reference; then
        PACKAGE_FORMAT=2
    else
        [[ "${OMEN_ACPI_UNVALIDATED_OPT_IN:-}" == "1" ]] \
            || die "Unvalidated machine requires the internal CLI opt-in indicator"
        PACKAGE_FORMAT=3
    fi
}

check_hybrid_graphics() {
    local vendor_file="/sys/bus/pci/devices/$EXPECTED_NVIDIA_BDF/vendor"
    local vendor=""

    [[ -r "$vendor_file" ]] \
        || die "The NVIDIA GPU is not visible at $EXPECTED_NVIDIA_BDF. Enable Hybrid graphics in firmware settings."
    vendor="$(cat "$vendor_file" 2>/dev/null || true)"
    [[ "${vendor,,}" == "0x10de" ]] \
        || die "Unexpected PCI vendor at $EXPECTED_NVIDIA_BDF: '$vendor'"
}

secure_boot_state() {
    local efivar value output

    shopt -s nullglob
    for efivar in /sys/firmware/efi/efivars/SecureBoot-*; do
        value="$(od -An -t u1 -j 4 -N 1 "$efivar" 2>/dev/null | tr -d '[:space:]' || true)"
        case "$value" in
            0)
                shopt -u nullglob
                printf 'disabled\n'
                return
                ;;
            1)
                shopt -u nullglob
                printf 'enabled\n'
                return
                ;;
        esac
    done
    shopt -u nullglob

    if command -v mokutil >/dev/null 2>&1; then
        output="$(mokutil --sb-state 2>/dev/null || true)"
        if grep -qi 'enabled' <<<"$output"; then
            printf 'enabled\n'
            return
        fi
        if grep -qi 'disabled' <<<"$output"; then
            printf 'disabled\n'
            return
        fi
    fi

    printf 'unknown\n'
}

check_secure_boot() {
    local state
    state="$(secure_boot_state)"
    case "$state" in
        disabled)
            ;;
        enabled)
            die "Secure Boot is enabled. Disable it before installing this experimental ACPI override."
            ;;
        *)
            die "Secure Boot state could not be verified. Installation stops closed."
            ;;
    esac
}

running_kernel_supports_table_upgrade() {
    local config

    if [[ -r /proc/config.gz ]]; then
        zgrep -q '^CONFIG_ACPI_TABLE_UPGRADE=y$' /proc/config.gz
        return
    fi

    for config in \
        "/boot/config-$(uname -r)" \
        "/usr/lib/modules/$(uname -r)/build/.config"; do
        if [[ -r "$config" ]]; then
            grep -q '^CONFIG_ACPI_TABLE_UPGRADE=y$' "$config"
            return
        fi
    done

    return 1
}

check_install_preconditions() {
    check_machine
    [[ -x "$BOOT_PROBE" ]] || die "Boot-state probe not found: $BOOT_PROBE"
    "$BOOT_PROBE" --require-stock
    check_hybrid_graphics
    check_secure_boot
    running_kernel_supports_table_upgrade \
        || die "The running kernel does not prove CONFIG_ACPI_TABLE_UPGRADE=y."
}

# Limine paths and ACPI transformation

parse_esp_path_from_defaults() {
    local defaults_file="$1"

    python3 - "$defaults_file" <<'PY'
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
values = []
for raw in path.read_text(encoding="utf-8", errors="strict").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip() != "ESP_PATH":
        continue
    parsed = shlex.split(value, comments=True, posix=True)
    if len(parsed) != 1:
        raise SystemExit("ESP_PATH is not a single literal path")
    values.append(parsed[0])

if len(values) > 1:
    raise SystemExit("ESP_PATH is defined more than once")
if values:
    print(values[0])
PY
}

find_esp() {
    local esp="" mount_target=""

    if command -v bootctl >/dev/null 2>&1; then
        esp="$(bootctl --print-esp-path 2>/dev/null || true)"
        if [[ -n "$esp" && ! -f "$esp/limine.conf" ]]; then
            esp=""
        fi
    fi

    if [[ -z "$esp" && -r /etc/default/limine ]]; then
        esp="$(parse_esp_path_from_defaults /etc/default/limine)"
    fi

    if [[ -z "$esp" && -f /boot/limine.conf ]]; then
        esp="/boot"
    fi

    [[ -n "$esp" ]] || die "Could not locate the Limine EFI system partition."
    [[ -d "$esp" ]] || die "EFI system partition is not a directory: $esp"
    esp="$(realpath -- "$esp")"
    [[ -f "$esp/limine.conf" ]] || die "Limine configuration not found: $esp/limine.conf"

    mount_target="$(findmnt -nro TARGET -T "$esp" 2>/dev/null | head -n 1 || true)"
    [[ -n "$mount_target" ]] || die "Could not verify that the EFI system partition is mounted: $esp"
    mount_target="$(realpath -- "$mount_target")"
    [[ "$mount_target" == "$esp" ]] \
        || die "The Limine directory is not a distinct mounted filesystem: $esp"

    printf '%s\n' "$esp"
}

resolve_limine_path() {
    local value="$1"
    local esp="$2"
    local relative resolved

    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "${value:0:1}" == '$' ]]; then
        value="${value:1}"
    fi

    if [[ "$value" =~ ^boot\(\):/(.*)$ ]]; then
        relative="${BASH_REMATCH[1]}"
    else
        die "Unsupported Limine path: $1"
    fi

    [[ -n "$relative" ]] || die "Empty Limine path: $1"
    [[ "$relative" != /* ]] || die "Absolute Limine payload path rejected: $1"
    [[ "/$relative/" != *"/../"* ]] || die "Parent traversal rejected in Limine path: $1"

    resolved="$(realpath -m -- "$esp/$relative")"
    case "$resolved" in
        "$esp"/*)
            ;;
        *)
            die "Limine path escapes the EFI system partition: $1"
            ;;
    esac

    printf '%s\n' "$resolved"
}

safe_copy_source_dsl() {
    local archive="$1"
    local destination="$2"
    local fingerprint_destination="$3"

    python3 - \
        "$archive" \
        "$destination" \
        "$fingerprint_destination" \
        "$VARIANT" \
        "$EXPECTED_PATCHED_REVISION" \
        "$MACHINE_PRODUCT" \
        "$MACHINE_BOARD" \
        "$MACHINE_BIOS" <<'PY'
from pathlib import Path, PurePosixPath
import os
import re
import tarfile
import tempfile
import sys

archive = Path(sys.argv[1])
destination = Path(sys.argv[2])
fingerprint_destination = Path(sys.argv[3])
expected_variant = sys.argv[4]
expected_revision = sys.argv[5]
machine = tuple(sys.argv[6:9])
reference = ("OMEN Gaming Laptop 16-ap0xxx", "8E35", "F.13")
maximum_size = 32 * 1024 * 1024

with tarfile.open(archive, mode="r:*") as tf:
    members = tf.getmembers()
    if not members or len(members) > 64:
        raise SystemExit(
            f"unexpected archive member count: {len(members)}; expected 1..64"
        )
    if sum(member.size for member in members if member.isfile()) > 64 * 1024 * 1024:
        raise SystemExit("archive members exceed the 64 MiB uncompressed safety limit")
    normalized_names = [str(PurePosixPath(member.name)) for member in members]
    if len(normalized_names) != len(set(normalized_names)):
        raise SystemExit("archive contains duplicate normalized paths")
    for member in members:
        name = PurePosixPath(member.name)
        if name.is_absolute() or ".." in name.parts:
            raise SystemExit(f"unsafe archive member path: {member.name!r}")
        if member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
            raise SystemExit(f"unsupported archive member type: {member.name!r}")

    matches = [
        member
        for member in members
        if member.isfile() and PurePosixPath(member.name).name == "DSDT-original.dsl"
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"expected exactly one regular DSDT-original.dsl; found {len(matches)}"
        )

    info_matches = [
        member
        for member in members
        if member.isfile() and PurePosixPath(member.name).name == "BUILD-INFO.txt"
    ]
    if len(info_matches) != 1:
        raise SystemExit(
            f"expected exactly one regular BUILD-INFO.txt; found {len(info_matches)}"
        )
    info_member = info_matches[0]
    if info_member.size <= 0 or info_member.size > 64 * 1024:
        raise SystemExit(f"unexpected BUILD-INFO.txt size: {info_member.size}")
    info_stream = tf.extractfile(info_member)
    if info_stream is None:
        raise SystemExit("could not read BUILD-INFO.txt")
    info_text = info_stream.read().decode("utf-8", "strict")
    metadata = {}
    for line in info_text.splitlines():
        if not line or "=" not in line:
            raise SystemExit("BUILD-INFO.txt contains a malformed line")
        key, value = line.split("=", 1)
        if key in metadata:
            raise SystemExit(f"duplicate BUILD-INFO.txt key: {key}")
        metadata[key] = value
    expected_metadata = {
        "PACKAGE_FORMAT": "2" if machine == reference else "3",
        "VARIANT": expected_variant,
        "WQBZ_WORKAROUND": "YES" if expected_variant == "combined" else "NO",
        "DMI_PRODUCT": machine[0],
        "MAINBOARD": machine[1],
        "BIOS": machine[2],
        "ORIGINAL_DSDT_OEM_REVISION": "0x01072009",
        "PATCHED_DSDT_OEM_REVISION": expected_revision,
    }
    for key, expected in expected_metadata.items():
        actual = metadata.get(key)
        if actual != expected:
            raise SystemExit(
                f"BUILD-INFO.txt mismatch for {key}: expected {expected!r}, "
                f"found {actual!r}"
            )
    fingerprint = metadata.get("ORIGINAL_DSDT_SHA256", "")
    if re.fullmatch(r"[0-9a-f]{64}", fingerprint) is None:
        raise SystemExit(
            "BUILD-INFO.txt contains an invalid original DSDT fingerprint"
        )

    member = matches[0]
    if member.size <= 0 or member.size > maximum_size:
        raise SystemExit(f"unexpected DSDT-original.dsl size: {member.size}")
    source = tf.extractfile(member)
    if source is None:
        raise SystemExit("could not read DSDT-original.dsl")

    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=".DSDT-original.", dir=destination.parent)
    total = 0
    try:
        with os.fdopen(fd, "wb") as output:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum_size:
                    raise SystemExit("DSDT-original.dsl exceeds the size limit")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if total != member.size:
            raise SystemExit("DSDT-original.dsl size changed during extraction")
        os.replace(temporary_name, destination)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass

    fingerprint_destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=".original-dsdt.", dir=fingerprint_destination.parent
    )
    try:
        with os.fdopen(fd, "w", encoding="ascii") as output:
            output.write(fingerprint + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, fingerprint_destination)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
PY
}

build_variant_dsdt() {
    local archive="$1"
    local work="$2"
    local source_dsl source_fingerprint patched_dsl aml roundtrip_dsl diff_status

    mkdir -p "$work/source" "$work/build" "$work/roundtrip"
    source_dsl="$work/source/DSDT-original.dsl"
    source_fingerprint="$work/source/original-dsdt.sha256"
    patched_dsl="$work/build/DSDT-OMEN-F13-${VARIANT}.dsl"
    safe_copy_source_dsl "$archive" "$source_dsl" "$source_fingerprint"
    ORIGINAL_DSDT_SHA256="$(tr -d '[:space:]' < "$source_fingerprint")"
    [[ "$ORIGINAL_DSDT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || die "The build archive did not provide a valid original DSDT fingerprint."

    python3 - "$source_dsl" "$patched_dsl" "$VARIANT" "$EXPECTED_PATCHED_REVISION" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
variant = sys.argv[3]
revision = sys.argv[4]
if variant not in {"s5", "combined"}:
    raise SystemExit(f"unsupported variant: {variant!r}")
if revision not in {"0x0107200A", "0x0107200B"}:
    raise SystemExit(f"unsupported patched revision: {revision!r}")
text = source.read_text(encoding="utf-8", errors="strict")

header_old = 'DefinitionBlock ("", "DSDT", 2, "HPQOEM", "8E35    ", 0x01072009)'
header_new = f'DefinitionBlock ("", "DSDT", 2, "HPQOEM", "8E35    ", {revision})'
if text.count(header_old) != 1:
    raise SystemExit(
        f"unexpected original DSDT header count: {text.count(header_old)}"
    )
if header_new in text:
    raise SystemExit("the source already carries the patched OEM revision")

external_anchor = "    External (_SB_.PCI0.GPP0.PEGP, DeviceObj)\n"
external_insert = (
    external_anchor
    + "    External (_SB_.PCI0.GPP0.PEGP.OMPR, IntObj)\n"
    + "    External (_SB_.PCI0.GPP0.PEGP._PS3, MethodObj)    // 0 Arguments\n"
)
if text.count(external_anchor) != 1:
    raise SystemExit(
        f"unexpected PEGP external anchor count: {text.count(external_anchor)}"
    )
if "External (_SB_.PCI0.GPP0.PEGP.OMPR," in text:
    raise SystemExit("OMPR external declaration is already present")
if "External (_SB_.PCI0.GPP0.PEGP._PS3," in text:
    raise SystemExit("_PS3 external declaration is already present")

pts_old = r'''    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep
    {
        If (Arg0)
        {
            PTS (Arg0)
            \_SB.TPM.TPTS (Arg0)
            MPTS (Arg0)
            SPTS (Arg0)
            \_SB.PCI0.GPTS (Arg0)
            \_SB.PCI0.NPTS (Arg0)
        }
    }
'''

pts_new = r'''    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep
    {
        If (Arg0)
        {
            PTS (Arg0)
            \_SB.TPM.TPTS (Arg0)
            MPTS (Arg0)
            SPTS (Arg0)
            \_SB.PCI0.GPTS (Arg0)
            \_SB.PCI0.NPTS (Arg0)

            /*
             * HP OMEN 16-ap0xxx, board 8E35, BIOS F.13.
             * Run the firmware's original discrete-GPU power-down path only
             * while preparing the S5 power-off state.
             */
            If (LEqual (Arg0, 0x05))
            {
                If (CondRefOf (\_SB.PCI0.GPP0.PEGP.OMPR))
                {
                    If (CondRefOf (\_SB.PCI0.GPP0.PEGP._PS3))
                    {
                        Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)
                        \_SB.PCI0.GPP0.PEGP._PS3 ()
                    }
                }
            }
        }
    }
'''

if text.count(pts_old) != 1:
    raise SystemExit(
        f"expected the original _PTS body exactly once; found {text.count(pts_old)}"
    )
text = text.replace(header_old, header_new, 1)
text = text.replace(external_anchor, external_insert, 1)
text = text.replace(pts_old, pts_new, 1)

loop_old = r'''                    While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))
                    {
                        Store (DerefOf (Index (BF01, Local5)), Local3)
                        Store (Local3, Index (N005, Local1))
                        Increment (Local5)
                        Increment (Local1)
                    }
'''

loop_new = r'''                    While (LLess (Local5, SizeOf (BF01)))
                    {
                        If (LEqual (DerefOf (Index (BF01, Local5)), Zero))
                        {
                            Break
                        }

                        Store (DerefOf (Index (BF01, Local5)), Local3)
                        Store (Local3, Index (N005, Local1))
                        Increment (Local5)
                        Increment (Local1)
                    }
'''

def method_block_span(source_text: str, method_name: str) -> tuple[int, int]:
    matches = list(
        re.finditer(
            rf"(?m)^\s*Method\s*\(\s*{re.escape(method_name)}\s*,",
            source_text,
        )
    )
    if len(matches) != 1:
        raise SystemExit(
            f"expected exactly one {method_name} method; found {len(matches)}"
        )
    opening = source_text.find("{", matches[0].end())
    if opening < 0:
        raise SystemExit(f"{method_name} has no opening brace")

    depth = 0
    index = opening
    in_string = False
    line_comment = False
    block_comment = False
    while index < len(source_text):
        char = source_text[index]
        following = source_text[index + 1] if index + 1 < len(source_text) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "*" and following == "/":
                block_comment = False
                index += 1
        elif in_string:
            if char == "\\":
                index += 1
            elif char == '"':
                in_string = False
        elif char == "/" and following == "/":
            line_comment = True
            index += 1
        elif char == "/" and following == "*":
            block_comment = True
            index += 1
        elif char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return matches[0].start(), index + 1
        index += 1
    raise SystemExit(f"{method_name} has no matching closing brace")

wqbz_start, wqbz_end = method_block_span(text, "WQBZ")
wqbz = text[wqbz_start:wqbz_end]
old_count = wqbz.count(loop_old)
bounded_count = wqbz.count(loop_new)
if old_count != 2 or text.count(loop_old) != 2:
    raise SystemExit(
        f"expected exactly two original BF01 loops inside WQBZ; found {old_count}"
    )
if bounded_count != 0 or loop_new in text:
    raise SystemExit("the source already contains a bounded BF01 loop")

if variant == "combined":
    patched_wqbz = wqbz.replace(loop_old, loop_new)
    text = text[:wqbz_start] + patched_wqbz + text[wqbz_end:]
    if text.count(loop_old) != 0 or patched_wqbz.count(loop_new) != 2:
        raise SystemExit("the two BF01 loop transformations are incomplete")
else:
    if text.count(loop_old) != 2 or text.count(loop_new) != 0:
        raise SystemExit("the S5-only variant changed the WQBZ loops unexpectedly")

required_once = (
    "If (CondRefOf (\\_SB.PCI0.GPP0.PEGP.OMPR))",
    "If (CondRefOf (\\_SB.PCI0.GPP0.PEGP._PS3))",
    "Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)",
    "\\_SB.PCI0.GPP0.PEGP._PS3 ()",
)
for fragment in required_once:
    if text.count(fragment) != 1:
        raise SystemExit(f"patched fragment is absent or ambiguous: {fragment}")

destination.write_text(text, encoding="utf-8")
PY

    if diff -u "$source_dsl" "$patched_dsl" > "$work/build/DSDT-${VARIANT}.patch"; then
        die "The deterministic $VARIANT patch is unexpectedly empty."
    else
        diff_status=$?
        (( diff_status == 1 )) || die "diff failed with status $diff_status."
    fi

    (
        cd "$work/build"
        iasl -tc "$(basename "$patched_dsl")" > compile.log 2>&1
    ) || {
        cat "$work/build/compile.log" >&2
        die "iASL failed to compile the $VARIANT DSDT."
    }

    aml="$work/build/DSDT-OMEN-F13-${VARIANT}.aml"
    [[ -s "$aml" ]] || die "iASL did not create the expected AML file."

    cp -a "$aml" "$work/roundtrip/DSDT.aml"
    (
        cd "$work/roundtrip"
        # Keep the disassembly dialect identical to the public builder.  Plain
        # `iasl -d` emits ASL+ indexing/operator syntax on current ACPICA,
        # whereas `-dl` preserves the legacy LNotEqual/Index form verified
        # below and by scripts/02-build-dsdt.sh.
        iasl -dl -d DSDT.aml > roundtrip.log 2>&1
    ) || {
        cat "$work/roundtrip/roundtrip.log" >&2
        die "The AML-to-DSL round trip failed."
    }

    roundtrip_dsl="$work/roundtrip/DSDT.dsl"
    [[ -s "$roundtrip_dsl" ]] || die "The round trip did not create DSDT.dsl."

    python3 - "$aml" "$roundtrip_dsl" "$VARIANT" "$EXPECTED_PATCHED_REVISION" <<'PY'
from pathlib import Path
import re
import struct
import sys

aml_path = Path(sys.argv[1])
roundtrip_path = Path(sys.argv[2])
variant = sys.argv[3]
expected_revision = int(sys.argv[4], 0)
data = aml_path.read_bytes()
text = roundtrip_path.read_text(encoding="utf-8", errors="strict")

if len(data) < 36:
    raise SystemExit("AML is shorter than an ACPI table header")

signature = data[0:4]
length = struct.unpack_from("<I", data, 4)[0]
oem_id = data[10:16].decode("ascii", "strict")
oem_table_id = data[16:24].decode("ascii", "strict")
oem_revision = struct.unpack_from("<I", data, 24)[0]

if signature != b"DSDT":
    raise SystemExit(f"unexpected ACPI signature: {signature!r}")
if length != len(data):
    raise SystemExit(f"AML length mismatch: header={length}, file={len(data)}")
if sum(data) & 0xFF:
    raise SystemExit("invalid ACPI checksum")
if oem_id != "HPQOEM":
    raise SystemExit(f"unexpected OEM ID: {oem_id!r}")
if oem_table_id != "8E35    ":
    raise SystemExit(f"unexpected OEM table ID: {oem_table_id!r}")
if oem_revision != expected_revision:
    raise SystemExit(f"unexpected OEM revision: 0x{oem_revision:08X}")

if variant not in {"s5", "combined"}:
    raise SystemExit(f"unsupported verification variant: {variant!r}")

def method_block_span(source_text: str, method_name: str) -> tuple[int, int]:
    matches = list(
        re.finditer(
            rf"(?m)^\s*Method\s*\(\s*{re.escape(method_name)}\s*,",
            source_text,
        )
    )
    if len(matches) != 1:
        raise SystemExit(
            f"round trip contains {len(matches)} {method_name} methods; expected one"
        )
    opening = source_text.find("{", matches[0].end())
    if opening < 0:
        raise SystemExit(f"round-trip {method_name} has no opening brace")

    depth = 0
    index = opening
    in_string = False
    line_comment = False
    block_comment = False
    while index < len(source_text):
        char = source_text[index]
        following = source_text[index + 1] if index + 1 < len(source_text) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "*" and following == "/":
                block_comment = False
                index += 1
        elif in_string:
            if char == "\\":
                index += 1
            elif char == '"':
                in_string = False
        elif char == "/" and following == "/":
            line_comment = True
            index += 1
        elif char == "/" and following == "*":
            block_comment = True
            index += 1
        elif char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return matches[0].start(), index + 1
        index += 1
    raise SystemExit(f"round-trip {method_name} has no matching closing brace")

pts_start, pts_end = method_block_span(text, "_PTS")
pts_text = text[pts_start:pts_end]
s5_guard = "If (LEqual (Arg0, 0x05))"
if pts_text.count(s5_guard) != 1:
    raise SystemExit(
        "round trip must contain exactly one S5 guard inside _PTS; "
        f"found {pts_text.count(s5_guard)}"
    )

critical_markers = (
    r"Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)",
    r"\_SB.PCI0.GPP0.PEGP._PS3 ()",
)
positions = [pts_text.index(s5_guard)]
for marker in critical_markers:
    global_count = text.count(marker)
    local_count = pts_text.count(marker)
    if global_count != 1 or local_count != 1:
        raise SystemExit(
            f"round-trip marker {marker!r} must occur exactly once inside _PTS; "
            f"found local={local_count}, global={global_count}"
        )
    positions.append(pts_text.index(marker))
if positions != sorted(positions):
    raise SystemExit("S5 operations are not ordered OMPR=3, _PS3")

for guard in (
    "If (CondRefOf (\\_SB.PCI0.GPP0.PEGP.OMPR))",
    "If (CondRefOf (\\_SB.PCI0.GPP0.PEGP._PS3))",
):
    if text.count(guard) != 1 or pts_text.count(guard) != 1:
        raise SystemExit(
            f"round-trip fail-closed guard {guard!r} is absent or ambiguous"
        )

wqbz_start, wqbz_end = method_block_span(text, "WQBZ")
wqbz_text = text[wqbz_start:wqbz_end]
original_loop = r'''                    While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))
                    {
                        Store (DerefOf (Index (BF01, Local5)), Local3)
                        Store (Local3, Index (N005, Local1))
                        Increment (Local5)
                        Increment (Local1)
                    }
'''
bounded_loop = r'''                    While (LLess (Local5, SizeOf (BF01)))
                    {
                        If (LEqual (DerefOf (Index (BF01, Local5)), Zero))
                        {
                            Break
                        }

                        Store (DerefOf (Index (BF01, Local5)), Local3)
                        Store (Local3, Index (N005, Local1))
                        Increment (Local5)
                        Increment (Local1)
                    }
'''

def normalize_whitespace(value: str) -> str:
    return " ".join(value.split())

normalized_text = normalize_whitespace(text)
normalized_wqbz = normalize_whitespace(wqbz_text)
normalized_original = normalize_whitespace(original_loop)
normalized_bounded = normalize_whitespace(bounded_loop)
global_original = normalized_text.count(normalized_original)
global_bounded = normalized_text.count(normalized_bounded)
wqbz_original = normalized_wqbz.count(normalized_original)
wqbz_bounded = normalized_wqbz.count(normalized_bounded)

if variant == "s5":
    if (
        global_original != 2
        or wqbz_original != 2
        or global_bounded != 0
        or wqbz_bounded != 0
    ):
        raise SystemExit(
            "S5 round trip must retain exactly two original WQBZ loops and no "
            "bounded loops; "
            f"found original(global={global_original}, WQBZ={wqbz_original}), "
            f"bounded(global={global_bounded}, WQBZ={wqbz_bounded})"
        )
else:
    if (
        global_original != 0
        or wqbz_original != 0
        or global_bounded != 2
        or wqbz_bounded != 2
    ):
        raise SystemExit(
            "Combined round trip must contain exactly two bounded WQBZ loops "
            "and no original loops; "
            f"found original(global={global_original}, WQBZ={wqbz_original}), "
            f"bounded(global={global_bounded}, WQBZ={wqbz_bounded})"
        )

print(
    f"Verified {variant} DSDT: {len(data)} bytes, "
    f"OEM revision 0x{oem_revision:08X}",
    file=sys.stderr,
)
PY

    BUILT_AML="$aml"
}

extract_normal_entry() {
    local config="$1"
    local output="$2"

    python3 - "$config" "$output" <<'PY'
from pathlib import Path
import re
import sys

config = Path(sys.argv[1])
output = Path(sys.argv[2])
lines = config.read_text(encoding="utf-8", errors="strict").splitlines()

entry_re = re.compile(r"^\s*(/+)(\+?)([^/].*)$")
option_re = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$")
entries = []
stack = []
for index, line in enumerate(lines):
    match = entry_re.match(line)
    if match is None:
        continue
    level = len(match.group(1))
    while stack and entries[stack[-1]]["level"] >= level:
        stack.pop()
    parent = stack[-1] if stack else None
    entries.append(
        {
            "start": index,
            "level": level,
            "parent": parent,
            "title": match.group(3).strip(),
        }
    )
    stack.append(len(entries) - 1)

for position, entry in enumerate(entries):
    entry["end"] = (
        entries[position + 1]["start"]
        if position + 1 < len(entries)
        else len(lines)
    )

supported = {"linux-cachyos", "linux-cachyos-lts"}

def historical(entry):
    parent = entry["parent"]
    while parent is not None:
        ancestor = entries[parent]
        if "snapshot" in ancestor["title"].lower():
            return True
        parent = ancestor["parent"]
    return False

exact_named = [
    entry for entry in entries
    if entry["title"].lower() in supported and not historical(entry)
]
if exact_named:
    shallowest_named_level = min(entry["level"] for entry in exact_named)
    evaluation_entries = [
        entry for entry in exact_named if entry["level"] == shallowest_named_level
    ]
else:
    evaluation_entries = entries

candidates = []
for entry in evaluation_entries:
    start = entry["start"]
    end = entry["end"]
    title = entry["title"]
    options = {}
    modules = []
    for line in lines[start + 1:end]:
        match = option_re.match(line)
        if not match:
            continue
        key = match.group(1).lower()
        value = match.group(2)
        if key == "module_path":
            modules.append(value)
        elif key == "comment":
            continue
        elif key in options:
            if title.lower() in supported:
                raise SystemExit(
                    f"normal CachyOS entry repeats boot option {key!r}"
                )
            options[key] = value
        else:
            options[key] = value

    protocol = options.get("protocol", "").lower()
    if protocol != "linux":
        continue
    kernel_aliases = [key for key in ("kernel_path", "path") if key in options]
    cmdline_aliases = [key for key in ("cmdline", "kernel_cmdline") if key in options]
    if len(kernel_aliases) != 1 or len(cmdline_aliases) > 1:
        if title.lower() in supported:
            raise SystemExit(
                "normal CachyOS entry contains ambiguous kernel or command-line aliases"
            )
        continue
    kernel = options[kernel_aliases[0]]
    cmdline = options[cmdline_aliases[0]] if cmdline_aliases else ""
    block = "\n".join(lines[start:end])
    searchable = f"{title}\n{kernel}\n{block}".lower()

    if not kernel or not modules:
        continue

    score = 0
    if title.lower() == "linux-cachyos":
        score += 300
    if title.lower() == "linux-cachyos-lts":
        score += 250
    if "linux-cachyos" in title.lower():
        score += 180
    if "kernel-id=linux-cachyos" in searchable:
        score += 220
    if "linux-cachyos" in kernel.lower():
        score += 100
    if any(
        word in searchable
        for word in ("fallback", "snapshot", "omen-acpi", "s5-test")
    ):
        score -= 1000

    candidates.append(
        (
            entry["level"],
            score,
            start,
            title,
            kernel,
            cmdline,
            modules,
        )
    )

if not candidates:
    raise SystemExit("no normal CachyOS Linux entry was found")

positive = [item for item in candidates if item[1] > 0]
if not positive:
    raise SystemExit("the normal CachyOS entry could not be identified safely")
shallowest_level = min(item[0] for item in positive)
shallow = [item for item in positive if item[0] == shallowest_level]
best_score = max(item[1] for item in shallow)
best = [item for item in shallow if item[1] == best_score]
if best_score <= 0:
    raise SystemExit("the normal CachyOS entry could not be identified safely")
if len(best) != 1:
    titles = ", ".join(repr(item[3]) for item in best)
    raise SystemExit(f"normal CachyOS entry selection is ambiguous: {titles}")

_, _, _, title, kernel, cmdline, modules = best[0]
cmdline = re.sub(r"(?<!\S)(?:initrd|BOOT_IMAGE)=[^\s]+", "", cmdline)
cmdline = re.sub(r"\s+", " ", cmdline).strip()

values = [title, kernel, cmdline, *modules]
if any("\n" in value or "\r" in value for value in values):
    raise SystemExit("entry metadata contains a line break")

with output.open("w", encoding="utf-8") as stream:
    for value in values:
        stream.write(value + "\n")
PY
}

# Legacy installation parsing

extract_exact_entry() {
    local config="$1"
    local entry_name="$2"
    local output="$3"

    python3 - "$config" "$entry_name" "$output" <<'PY'
from pathlib import Path
import re
import sys

config = Path(sys.argv[1])
entry_name = sys.argv[2]
output = Path(sys.argv[3])
lines = config.read_text(encoding="utf-8", errors="strict").splitlines()

entry_re = re.compile(r"^\s*(/+)(\+?)([^/].*)$")
option_re = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$")
entries = []
stack = []
for index, line in enumerate(lines):
    match = entry_re.match(line)
    if match is None:
        continue
    level = len(match.group(1))
    while stack and entries[stack[-1]]["level"] >= level:
        stack.pop()
    parent = stack[-1] if stack else None
    entries.append(
        {
            "start": index,
            "level": level,
            "parent": parent,
            "title": match.group(3).strip(),
        }
    )
    stack.append(len(entries) - 1)

for position, entry in enumerate(entries):
    entry["end"] = (
        entries[position + 1]["start"]
        if position + 1 < len(entries)
        else len(lines)
    )

normal_named = [entry for entry in entries if entry["title"].lower() == "linux-cachyos"]
if not normal_named:
    raise SystemExit("normal CachyOS namespace is missing")
normal_level = min(entry["level"] for entry in normal_named)
normal_matches = [entry for entry in normal_named if entry["level"] == normal_level]
if len(normal_matches) != 1:
    raise SystemExit("normal CachyOS namespace is ambiguous")
normal_entry = normal_matches[0]

normal_options = {}
normal_modules = []
for line in lines[normal_entry["start"] + 1:normal_entry["end"]]:
    match = option_re.match(line)
    if match is None:
        continue
    key = match.group(1).lower()
    value = match.group(2)
    if key == "module_path":
        normal_modules.append(value)
    elif key == "comment":
        continue
    elif key in normal_options:
        raise SystemExit(f"normal CachyOS entry repeats boot option {key!r}")
    else:
        normal_options[key] = value
normal_kernel_aliases = [
    key for key in ("kernel_path", "path") if key in normal_options
]
normal_cmdline_aliases = [
    key for key in ("cmdline", "kernel_cmdline") if key in normal_options
]
if (
    normal_options.get("protocol", "").lower() != "linux"
    or len(normal_kernel_aliases) != 1
    or len(normal_cmdline_aliases) > 1
    or not normal_modules
):
    raise SystemExit("normal CachyOS namespace is malformed")

matches = []
for entry in entries:
    if (
        entry["title"] != entry_name
        or entry["level"] != normal_entry["level"]
        or entry["parent"] != normal_entry["parent"]
    ):
        continue
    start = entry["start"]
    end = entry["end"]
    title = entry["title"]
    options = {}
    modules = []
    for line in lines[start + 1:end]:
        match = option_re.match(line)
        if not match:
            continue
        key = match.group(1).lower()
        value = match.group(2)
        if key == "module_path":
            modules.append(value)
        elif key == "comment":
            # limine-entry-tool may emit more than one descriptive comment.
            # Comments do not affect boot semantics, so ignore only this key;
            # every boot-relevant singleton remains protected below.
            continue
        elif key in options:
            raise SystemExit(f"duplicate option {key!r} in reserved entry")
        else:
            options[key] = value
    protocol = options.get("protocol", "").lower()
    kernel_aliases = [key for key in ("kernel_path", "path") if key in options]
    cmdline_aliases = [key for key in ("cmdline", "kernel_cmdline") if key in options]
    if len(kernel_aliases) != 1 or len(cmdline_aliases) > 1:
        raise SystemExit("reserved entry contains ambiguous kernel or command-line aliases")
    kernel = options[kernel_aliases[0]]
    cmdline = options[cmdline_aliases[0]] if cmdline_aliases else ""
    if protocol != "linux" or not kernel or len(modules) != 1:
        raise SystemExit("reserved entry is not an exact one-module Linux entry")
    matches.append((title, kernel, cmdline, modules[0]))

if len(matches) != 1:
    raise SystemExit(
        f"expected exactly one reserved entry named {entry_name!r}; found {len(matches)}"
    )

values = matches[0]
if any("\n" in value or "\r" in value or "\0" in value for value in values):
    raise SystemExit("reserved entry metadata contains an invalid character")
output.write_text("".join(value + "\n" for value in values), encoding="utf-8")
PY
}

load_normal_entry() {
    local esp="$1"
    local meta_file="$2"
    local -a lines
    local module

    extract_normal_entry "$esp/limine.conf" "$meta_file"
    mapfile -t lines < "$meta_file"
    ((${#lines[@]} >= 4)) || die "Normal Limine entry metadata is incomplete."

    NORMAL_TITLE="${lines[0]}"
    NORMAL_KERNEL_LIMINE="${lines[1]}"
    NORMAL_CMDLINE="${lines[2]}"
    [[ "$NORMAL_CMDLINE" != *"omen_acpi.variant="* ]] \
        || die "The normal Limine entry unexpectedly contains an OMEN ACPI variant marker."
    NORMAL_KERNEL_LOCAL="$(resolve_limine_path "$NORMAL_KERNEL_LIMINE" "$esp")"
    [[ -s "$NORMAL_KERNEL_LOCAL" ]] \
        || die "Normal-entry kernel not found: $NORMAL_KERNEL_LOCAL"

    NORMAL_MODULES_LIMINE=("${lines[@]:3}")
    NORMAL_MODULES_LOCAL=()
    for module in "${NORMAL_MODULES_LIMINE[@]}"; do
        module="$(resolve_limine_path "$module" "$esp")"
        [[ -s "$module" ]] || die "Normal-entry initramfs module not found: $module"
        NORMAL_MODULES_LOCAL+=("$module")
    done
}

sha256_file() {
    sha256sum -- "$1" | awk '{print $1}'
}

legacy_state_metadata() {
    local state_dir="${1:-$STATE_DIR}" expected_owner=0
    if [[ "${OMEN_ACPI_TESTING:-0}" == "1" ]]; then
        expected_owner="$EUID"
    fi
    python3 - \
        "$state_dir" \
        "$LEGACY_AML_NAME" \
        "$LEGACY_DSL_NAME" \
        "$LEGACY_BUILD_AML_NAME" \
        "$LEGACY_TEMP_PREFIX" \
        "$LEGACY_COMPOSITE_NAME" \
        "$EXPECTED_PATCHED_REVISION" \
        "$expected_owner" <<'PY'
from pathlib import Path
import hashlib
import os
import re
import stat
import struct
import sys

state = Path(sys.argv[1])
aml_name = sys.argv[2]
dsl_name = sys.argv[3]
build_aml_name = sys.argv[4]
temp_prefix = sys.argv[5]
composite_name = sys.argv[6]
expected_revision = int(sys.argv[7], 0)
expected_owner = int(sys.argv[8])

required = {
    "limine.conf.before",
    aml_name,
    dsl_name,
    "compile.log",
    "SHA256SUMS",
    "source-archive.txt",
    "kernel-version.txt",
    "source-entry.txt",
}
allowed = required | {"dropin.before"}


def safe_stat(path: Path, *, directory: bool = False) -> os.stat_result:
    details = path.lstat()
    expected = stat.S_ISDIR(details.st_mode) if directory else stat.S_ISREG(details.st_mode)
    if not expected or stat.S_ISLNK(details.st_mode):
        raise SystemExit(1)
    if details.st_uid != expected_owner or details.st_mode & 0o022:
        raise SystemExit(1)
    return details


try:
    safe_stat(state, directory=True)
    names = {item.name for item in state.iterdir()}
    if not required <= names or not names <= allowed:
        raise SystemExit(1)
    total_size = 0
    for name in names:
        details = safe_stat(state / name)
        if details.st_size > 32 * 1024 * 1024:
            raise SystemExit(1)
        total_size += details.st_size
    if total_size > 128 * 1024 * 1024:
        raise SystemExit(1)

    aml = (state / aml_name).read_bytes()
    if len(aml) < 36 or len(aml) > 16 * 1024 * 1024:
        raise SystemExit(1)
    if aml[:4] != b"DSDT" or struct.unpack_from("<I", aml, 4)[0] != len(aml):
        raise SystemExit(1)
    if sum(aml) & 0xFF:
        raise SystemExit(1)
    if aml[10:16] != b"HPQOEM" or aml[16:24] != b"8E35    ":
        raise SystemExit(1)
    if struct.unpack_from("<I", aml, 24)[0] != expected_revision:
        raise SystemExit(1)
    aml_digest = hashlib.sha256(aml).hexdigest()

    source_lines = (state / "source-archive.txt").read_text(
        encoding="utf-8", errors="strict"
    ).splitlines()
    if len(source_lines) != 1 or not source_lines[0].startswith("/"):
        raise SystemExit(1)
    source_path = source_lines[0]

    manifest_lines = (state / "SHA256SUMS").read_text(
        encoding="utf-8", errors="strict"
    ).splitlines()
    if len(manifest_lines) != 3:
        raise SystemExit(1)
    records = []
    for line in manifest_lines:
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise SystemExit(1)
        records.append(match.groups())
    if records[0][1] != source_path:
        raise SystemExit(1)

    temporary_root = rf"/var/tmp/{re.escape(temp_prefix)}\.[A-Za-z0-9]{{6}}"
    if re.fullmatch(
        temporary_root + rf"/build/{re.escape(build_aml_name)}", records[1][1]
    ) is None:
        raise SystemExit(1)
    if re.fullmatch(
        temporary_root + rf"/{re.escape(composite_name)}", records[2][1]
    ) is None:
        raise SystemExit(1)
    if records[1][0] != aml_digest:
        raise SystemExit(1)

    aml_manifest_path = Path(records[1][1])
    initramfs_manifest_path = Path(records[2][1])
    if aml_manifest_path.parent.parent != initramfs_manifest_path.parent:
        raise SystemExit(1)

    for one_line_name in ("kernel-version.txt", "source-entry.txt"):
        values = (state / one_line_name).read_text(
            encoding="utf-8", errors="strict"
        ).splitlines()
        if len(values) != 1 or not values[0] or "\0" in values[0]:
            raise SystemExit(1)
except (OSError, UnicodeError, ValueError, struct.error):
    raise SystemExit(1)

print(f"{aml_digest}\t{records[2][0]}")
PY
}

legacy_state_hash() {
    local state_dir="${1:-$STATE_DIR}" metadata
    metadata="$(legacy_state_metadata "$state_dir" 2>/dev/null)" || return 1
    [[ "$metadata" == *$'\t'* ]] || return 1
    printf '%s\n' "${metadata%%$'\t'*}"
}

legacy_initramfs_hash() {
    local state_dir="${1:-$STATE_DIR}" metadata
    metadata="$(legacy_state_metadata "$state_dir" 2>/dev/null)" || return 1
    [[ "$metadata" == *$'\t'* ]] || return 1
    printf '%s\n' "${metadata#*$'\t'}"
}

legacy_dropin_cmdline() {
    local dropin="${1:-$DROPIN}" expected_owner=0
    if [[ "${OMEN_ACPI_TESTING:-0}" == "1" ]]; then
        expected_owner="$EUID"
    fi
    python3 - "$dropin" "$ENTRY_NAME" "$LEGACY_DROPIN_COMMENT" "$expected_owner" <<'PY'
from pathlib import Path
import json
import os
import re
import stat
import sys

path = Path(sys.argv[1])
expected_entry = sys.argv[2]
expected_comment = sys.argv[3]
expected_owner = int(sys.argv[4])
try:
    details = path.lstat()
    if (
        not stat.S_ISREG(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or details.st_uid != expected_owner
        or details.st_mode & 0o022
        or details.st_size > 1024 * 1024
    ):
        raise SystemExit(1)
    lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)

if len(lines) != 2 or lines[0] != expected_comment:
    raise SystemExit(1)
json_string = r'"(?:\\.|[^"\\])*"'
match = re.fullmatch(
    rf"KERNEL_CMDLINE\[({json_string})\]=({json_string})", lines[1]
)
if match is None:
    raise SystemExit(1)
try:
    entry = json.loads(match.group(1))
    cmdline = json.loads(match.group(2))
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
if entry != expected_entry or not isinstance(cmdline, str):
    raise SystemExit(1)
if any(character in cmdline for character in ("\n", "\r", "\0")):
    raise SystemExit(1)
if any(token.startswith("omen_acpi.variant=") for token in cmdline.split()):
    raise SystemExit(1)
print(cmdline)
PY
}

write_normal_assets() {
    local destination="$1"
    local index

    {
        printf 'kernel\t%s\t%s\n' \
            "$(sha256_file "$NORMAL_KERNEL_LOCAL")" \
            "$NORMAL_KERNEL_LIMINE"
        for index in "${!NORMAL_MODULES_LOCAL[@]}"; do
            printf 'module\t%s\t%s\n' \
                "$(sha256_file "${NORMAL_MODULES_LOCAL[$index]}")" \
                "${NORMAL_MODULES_LIMINE[$index]}"
        done
    } > "$destination"
}

check_source_initramfs() {
    local module listing

    for module in "${NORMAL_MODULES_LOCAL[@]}"; do
        if ! listing="$(lsinitcpio "$module" 2>/dev/null)"; then
            die "Could not inspect normal-entry initramfs module: $module"
        fi
        if grep -q '^kernel/firmware/acpi/' <<<"$listing"; then
            die "The normal entry already contains an ACPI table override: $module"
        fi
    done
}

build_early_initramfs() {
    local aml="$1"
    local work="$2"
    local destination="$3"
    local early_dir

    early_dir="$work/early"
    mkdir -p "$early_dir/kernel/firmware/acpi"
    install -m 0644 "$aml" "$early_dir/kernel/firmware/acpi/DSDT.aml"

    (
        cd "$early_dir"
        printf '%s\0' \
            kernel \
            kernel/firmware \
            kernel/firmware/acpi \
            kernel/firmware/acpi/DSDT.aml \
        | cpio --null --create --format=newc --owner=0:0 --quiet \
        > "$destination"
    )
    chmod 0600 "$destination"
}

# Managed state and ownership checks

write_dropin_file() {
    local destination="$1"
    local cmdline="$2"

    python3 - "$destination" "$ENTRY_NAME" "$cmdline" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
entry = sys.argv[2]
cmdline = sys.argv[3]
content = (
    "# Managed by OMEN ACPI Toolkit; do not edit while installed.\n"
    f"KERNEL_CMDLINE[{json.dumps(entry)}]={json.dumps(cmdline)}\n"
)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(content, encoding="utf-8")
PY
    chmod 0644 "$destination"
}

config_entry_count() {
    local config="$1"
    python3 - "$config" "$ENTRY_NAME" <<'PY'
from pathlib import Path
import re
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict").splitlines()
entry_name = sys.argv[2]
entry_re = re.compile(r"^\s*(/+)(\+?)([^/].*)$")
entries = []
stack = []
for index, line in enumerate(lines):
    match = entry_re.match(line)
    if match is None:
        continue
    level = len(match.group(1))
    while stack and entries[stack[-1]]["level"] >= level:
        stack.pop()
    parent = stack[-1] if stack else None
    entries.append(
        {
            "index": index,
            "level": level,
            "parent": parent,
            "title": match.group(3).strip(),
        }
    )
    stack.append(len(entries) - 1)

# Snapper copies complete Limine entries below its snapshot hierarchy.  Only
# entries beside the shallowest, unique normal CachyOS entry belong to the
# active boot namespace; deeper copies are immutable historical snapshots.
normal_named = [entry for entry in entries if entry["title"].lower() == "linux-cachyos"]
if not normal_named:
    raise SystemExit("normal CachyOS namespace is missing")
normal_level = min(entry["level"] for entry in normal_named)
normal_matches = [entry for entry in normal_named if entry["level"] == normal_level]
if len(normal_matches) != 1:
    raise SystemExit("normal CachyOS namespace is ambiguous")
normal_entry = normal_matches[0]

count = sum(
    entry["title"] == entry_name
    and entry["level"] == normal_entry["level"]
    and entry["parent"] == normal_entry["parent"]
    for entry in entries
)
print(count)
PY
}

config_contains_entry() {
    local count
    count="$(config_entry_count "$1")" || return 1
    [[ "$count" == "1" ]]
}

safe_root_regular_file() {
    local path="$1" permissions expected_owner=0
    if [[ "${OMEN_ACPI_TESTING:-0}" == "1" ]]; then
        expected_owner="$EUID"
    fi
    [[ -f "$path" && ! -L "$path" \
        && "$(stat -c '%u' -- "$path")" == "$expected_owner" ]] \
        || return 1
    permissions="$(stat -c '%A' -- "$path")"
    [[ "${permissions:5:1}" != "w" && "${permissions:8:1}" != "w" ]]
}

validate_legacy_installation() {
    local esp="$1" work="$2" state_dir="${3:-$STATE_DIR}" dropin="${4:-$DROPIN}"
    local config metadata expected_module_hash
    local dropin_cmdline source_title kernel_path entry_cmdline module_path
    local kernel_local module_local
    local -a entry_lines

    metadata="$(legacy_state_metadata "$state_dir")" \
        || die "The legacy $VARIANT state is incomplete, modified or unsafe."
    expected_module_hash="${metadata#*$'\t'}"
    [[ "$expected_module_hash" =~ ^[0-9a-f]{64}$ ]] \
        || die "The legacy $VARIANT initramfs fingerprint is invalid."
    dropin_cmdline="$(legacy_dropin_cmdline "$dropin")" \
        || die "The legacy $VARIANT command-line drop-in is missing, modified or unsafe."

    config="$esp/limine.conf"
    safe_root_regular_file "$config" \
        || die "The mounted Limine configuration is not a safe root-owned file."
    extract_exact_entry "$config" "$ENTRY_NAME" "$work/legacy-entry.txt" \
        || die "The legacy $VARIANT Limine entry is missing, duplicated or malformed."
    mapfile -t entry_lines < "$work/legacy-entry.txt"
    ((${#entry_lines[@]} == 4)) \
        || die "The legacy $VARIANT entry metadata is incomplete."
    [[ "${entry_lines[0]}" == "$ENTRY_NAME" ]] \
        || die "The legacy $VARIANT entry title does not match its reserved name."
    kernel_path="${entry_lines[1]}"
    entry_cmdline="${entry_lines[2]}"
    module_path="${entry_lines[3]}"
    [[ "$entry_cmdline" == "$dropin_cmdline" ]] \
        || die "The legacy entry command line does not match its drop-in."

    kernel_local="$(resolve_limine_path "$kernel_path" "$esp")"
    module_local="$(resolve_limine_path "$module_path" "$esp")"
    safe_root_regular_file "$kernel_local" \
        || die "The legacy entry kernel is missing or unsafe: $kernel_local"
    safe_root_regular_file "$module_local" \
        || die "The legacy entry initramfs is missing or unsafe: $module_local"
    [[ "$(sha256_file "$module_local")" == "$expected_module_hash" ]] \
        || die "The legacy entry initramfs no longer matches its recorded fingerprint."

    load_normal_entry "$esp" "$work/normal-entry.txt"
    source_title="$(tr -d '\r\n' < "$state_dir/source-entry.txt")"
    [[ -n "$source_title" ]] \
        || die "The legacy state has an empty source-entry record."

    printf '%s\n' "$kernel_local" > "$work/legacy-kernel.path" \
        || die "Could not stage the legacy kernel path."
    printf '%s\n' "$module_local" > "$work/legacy-initramfs.path" \
        || die "Could not stage the legacy initramfs path."
    printf '%s\n' "$dropin_cmdline" > "$work/legacy-cmdline.txt" \
        || die "Could not stage the legacy command line."
}

state_machine() {
    local -a values=()
    [[ -f "$STATE_DIR/machine.txt" && ! -L "$STATE_DIR/machine.txt" \
        && -f "$STATE_DIR/machine.sha256" && ! -L "$STATE_DIR/machine.sha256" ]] \
        || return 1
    [[ "$(sha256_file "$STATE_DIR/machine.txt")" == "$(<"$STATE_DIR/machine.sha256")" ]] \
        || return 1
    mapfile -t values < "$STATE_DIR/machine.txt"
    ((${#values[@]} == 3)) \
        && [[ -n "${values[0]}" && -n "${values[1]}" && -n "${values[2]}" ]] \
        || return 1
    printf '%s\t%s\t%s\n' "${values[0]}" "${values[1]}" "${values[2]}"
}

managed_state_valid() {
    local stored_hash actual_hash manager_version=''
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || return 1
    for file in variant.txt expected-revision.txt DSDT.aml DSDT.sha256; do
        [[ -f "$STATE_DIR/$file" && ! -L "$STATE_DIR/$file" ]] || return 1
    done
    [[ "$(tr -d '\r\n' < "$STATE_DIR/variant.txt")" == "$VARIANT" ]] || return 1
    [[ "$(tr -d '\r\n' < "$STATE_DIR/expected-revision.txt")" == "$EXPECTED_PATCHED_REVISION" ]] \
        || return 1
    stored_hash="$(tr -d '[:space:]' < "$STATE_DIR/DSDT.sha256")"
    [[ "$stored_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_hash="$(sha256_file "$STATE_DIR/DSDT.aml")"
    [[ "$actual_hash" == "$stored_hash" ]] || return 1
    if [[ -e "$STATE_DIR/kernel-entries.json" || -L "$STATE_DIR/kernel-entries.json" ]]; then
        for file in kernel-entries.json early.cpio early.sha256; do
            [[ -f "$STATE_DIR/$file" && ! -L "$STATE_DIR/$file" ]] || return 1
        done
        [[ "$(sha256_file "$STATE_DIR/early.cpio")" == "$(tr -d '[:space:]' < "$STATE_DIR/early.sha256")" ]] \
            || return 1
    fi
    if [[ -f "$STATE_DIR/manager-version.txt" && ! -L "$STATE_DIR/manager-version.txt" ]]; then
        manager_version="$(<"$STATE_DIR/manager-version.txt")"
    fi
    if [[ "$manager_version" == "2.2.0" \
        || -e "$STATE_DIR/machine.txt" || -L "$STATE_DIR/machine.txt" \
        || -e "$STATE_DIR/machine.sha256" || -L "$STATE_DIR/machine.sha256" ]]; then
        state_machine >/dev/null
    fi
}

verify_owned_dropin() {
    safe_root_regular_file "$STATE_DIR/dropin.sha256" \
        || die "Installed state does not contain a drop-in checksum."
    safe_root_regular_file "$DROPIN" \
        || die "Managed Limine drop-in is missing or unsafe: $DROPIN"
    [[ "$(sha256_file "$DROPIN")" == "$(<"$STATE_DIR/dropin.sha256")" ]] \
        || die "Managed Limine drop-in was modified. Refusing to overwrite or remove it."
}

verify_state_identity() {
    local manager_version=''
    safe_root_regular_file "$STATE_DIR/variant.txt" \
        || die "Managed state does not identify its variant."
    [[ "$(<"$STATE_DIR/variant.txt")" == "$VARIANT" ]] \
        || die "Managed state variant does not match '$VARIANT'."
    safe_root_regular_file "$STATE_DIR/expected-revision.txt" \
        || die "Managed state does not contain its expected OEM revision."
    [[ "$(<"$STATE_DIR/expected-revision.txt")" == "$EXPECTED_PATCHED_REVISION" ]] \
        || die "Managed state OEM revision does not match variant '$VARIANT'."
    if [[ -f "$STATE_DIR/manager-version.txt" && ! -L "$STATE_DIR/manager-version.txt" ]]; then
        manager_version="$(<"$STATE_DIR/manager-version.txt")"
    fi
    if [[ "$manager_version" == "2.2.0" \
        || -e "$STATE_DIR/machine.txt" || -L "$STATE_DIR/machine.txt" \
        || -e "$STATE_DIR/machine.sha256" || -L "$STATE_DIR/machine.sha256" ]]; then
        state_machine >/dev/null \
            || die "Managed state machine identity is missing or modified."
    fi
    # Older pre-release state directories did not retain this provenance file;
    # keep status/removal available for them.  New installs always create it.
    if [[ -e "$STATE_DIR/original-dsdt.sha256" \
        || -L "$STATE_DIR/original-dsdt.sha256" ]]; then
        [[ -f "$STATE_DIR/original-dsdt.sha256" \
            && ! -L "$STATE_DIR/original-dsdt.sha256" ]] \
            || die "Managed state contains an unsafe stock DSDT fingerprint file."
        [[ "$(tr -d '[:space:]' < "$STATE_DIR/original-dsdt.sha256")" =~ ^[0-9a-f]{64}$ ]] \
            || die "Managed state contains an invalid stock DSDT fingerprint."
    fi
}

stored_source_archive_valid() {
    [[ -f "$STATE_DIR/source-build.tar.gz" && -f "$STATE_DIR/source-build.sha256" ]] \
        || return 1
    [[ "$(sha256_file "$STATE_DIR/source-build.tar.gz")" == "$(<"$STATE_DIR/source-build.sha256")" ]]
}

prepare_candidate_state() {
    local archive="$1"
    local esp="$2"
    local work="$3"
    local candidate="$4"
    local aml early free_bytes needed_bytes trusted_archive archive_size
    local live_dsdt live_dsdt_sha

    mkdir -p "$candidate"
    chmod 0700 "$candidate"

    archive_size="$(stat -c '%s' -- "$archive")"
    [[ "$archive_size" =~ ^[0-9]+$ ]] \
        || die "Could not measure the supplied build archive."
    (( archive_size > 0 && archive_size <= 67108864 )) \
        || die "The supplied build archive is empty or exceeds the 64 MiB safety limit."
    trusted_archive="$work/source-build.tar.gz"
    install -o root -g root -m 0600 -- "$archive" "$trusted_archive"

    BUILT_AML=""
    build_variant_dsdt "$trusted_archive" "$work"
    aml="$BUILT_AML"
    [[ -n "$aml" && -s "$aml" ]] \
        || die "The verified $VARIANT AML output was not produced."
    live_dsdt="/sys/firmware/acpi/tables/DSDT"
    [[ -r "$live_dsdt" ]] \
        || die "The live stock DSDT is no longer readable."
    live_dsdt_sha="$(sha256_file "$live_dsdt")"
    [[ "$live_dsdt_sha" == "$ORIGINAL_DSDT_SHA256" ]] \
        || die "The build archive was collected from a different stock DSDT. Collect and build it again on this clean stock boot."
    [[ -x "$KERNEL_ENTRIES" ]] \
        || die "Multi-kernel entry manager not found: $KERNEL_ENTRIES"
    "$KERNEL_ENTRIES" list --esp "$esp" > "$work/kernels.txt" \
        || die "Installed CachyOS kernels could not be validated."

    early="$work/omen-acpi-${VARIANT}-early.cpio"
    build_early_initramfs "$aml" "$work" "$early"

    needed_bytes=$((
        $(stat -c '%s' "$early")
        + 16777216
    ))
    free_bytes="$(df --output=avail -B1 "$esp" | tail -n 1 | tr -d '[:space:]')"
    [[ "$free_bytes" =~ ^[0-9]+$ ]] \
        || die "Could not measure free space on the EFI system partition."
    (( free_bytes >= needed_bytes )) \
        || die "Insufficient free space on the EFI system partition; approximately $needed_bytes bytes are required."

    cp -a "$trusted_archive" "$candidate/source-build.tar.gz"
    cp -a "$aml" "$candidate/DSDT.aml"
    cp -a "$work/source/DSDT-original.dsl" "$candidate/DSDT-original.dsl"
    cp -a "$work/build/DSDT-OMEN-F13-${VARIANT}.dsl" "$candidate/DSDT-patched.dsl"
    cp -a "$work/build/DSDT-${VARIANT}.patch" "$candidate/DSDT.patch"
    cp -a "$work/build/compile.log" "$candidate/compile.log"
    cp -a "$work/roundtrip/roundtrip.log" "$candidate/roundtrip.log"
    cp -a "$early" "$candidate/early.cpio"

    printf '%s\n' "$VERSION" > "$candidate/manager-version.txt"
    printf '%s\n' "$VARIANT" > "$candidate/variant.txt"
    printf '%s\n' "$esp" > "$candidate/esp-path.txt"
    printf '%s\n' 'dynamic:linux-cachyos,linux-cachyos-lts' > "$candidate/source-entry.txt"
    printf '%s\n' "$EXPECTED_PATCHED_REVISION" > "$candidate/expected-revision.txt"
    printf '%s\n' "$ORIGINAL_DSDT_SHA256" > "$candidate/original-dsdt.sha256"
    printf '%s\n%s\n%s\n' "$MACHINE_PRODUCT" "$MACHINE_BOARD" "$MACHINE_BIOS" \
        > "$candidate/machine.txt"
    sha256_file "$candidate/machine.txt" > "$candidate/machine.sha256"
    printf '%s\n' "$(date --iso-8601=seconds)" > "$candidate/created-at.txt"
    sha256_file "$candidate/source-build.tar.gz" > "$candidate/source-build.sha256"
    sha256_file "$candidate/DSDT.aml" > "$candidate/DSDT.sha256"
    sha256_file "$candidate/early.cpio" > "$candidate/early.sha256"

    chown -R root:root "$candidate"
    find "$candidate" -type f -exec chmod 0600 {} +
}

install_dropin() {
    local source="$1"
    mkdir -p "$(dirname "$DROPIN")"
    install -o root -g root -m 0644 "$source" "$DROPIN"
}

add_test_entry() {
    local candidate="$1" comment

    if [[ "$PACKAGE_FORMAT" == "2" ]]; then
        comment="EXPERIMENTAL: HP OMEN F.13 ${VARIANT} DSDT; normal entry unchanged"
    else
        comment="EXPERIMENTAL: unvalidated opt-in ${VARIANT} DSDT; normal entry unchanged"
    fi

    limine-entry-tool --add-kernel \
        "$ENTRY_NAME" \
        "$candidate/initramfs.img" \
        "$candidate/kernel.img" \
        --comment "$comment" \
        --quiet
}

safe_remove_temp_dir() {
    local directory="${1:-}"
    case "$directory" in
        /var/tmp/omen-acpi-override.*|\
        /var/lib/.omen-acpi-override-state.*)
            rm -rf -- "$directory"
            ;;
        "")
            ;;
        *)
            warn "Refusing to remove an unexpected temporary path: $directory"
            ;;
    esac
}

cleanup_override_action() {
    local original_status=$?

    if ! safe_remove_temp_dir "${ACTION_CLEANUP_WORK:-}"; then
        warn "Could not remove the temporary build directory during cleanup."
    fi
    if (( ! ${ACTION_CLEANUP_PRESERVE_CANDIDATE:-0} )); then
        if ! safe_remove_temp_dir "${ACTION_CLEANUP_CANDIDATE:-}"; then
            warn "Could not remove the temporary candidate state during cleanup."
        fi
    fi
    return "$original_status"
}

arm_override_cleanup() {
    ACTION_CLEANUP_WORK="${1:-}"
    ACTION_CLEANUP_CANDIDATE="${2:-}"
    ACTION_CLEANUP_PRESERVE_CANDIDATE=0
    trap cleanup_override_action EXIT
}

preserve_override_candidate() {
    ACTION_CLEANUP_PRESERVE_CANDIDATE=1
}

disarm_override_cleanup() {
    trap - EXIT
    ACTION_CLEANUP_WORK=""
    ACTION_CLEANUP_CANDIDATE=""
    ACTION_CLEANUP_PRESERVE_CANDIDATE=0
}

rollback_new_install() {
    local config="$1"
    local backup="$2"
    local candidate="$3"
    local failed=0

    warn "Installation failed; restoring the pre-install Limine configuration."
    if config_contains_entry "$config"; then
        limine-entry-tool --remove-kernel "$ENTRY_NAME" --quiet >/dev/null 2>&1 \
            || failed=1
    fi
    cp -a "$backup" "$config" || failed=1
    if [[ -e "$DROPIN" ]]; then
        if [[ -f "$candidate/dropin.sha256" ]] \
            && [[ "$(sha256_file "$DROPIN")" == "$(<"$candidate/dropin.sha256")" ]]; then
            rm -f -- "$DROPIN" || failed=1
        else
            warn "The command-line drop-in changed during rollback; it was preserved."
            failed=1
        fi
    fi
    sync || failed=1

    if (( failed )); then
        warn "Automatic rollback was incomplete. Recovery material is preserved at: $candidate"
        return 1
    fi
    return 0
}

commit_new_install() {
    local config="$1"
    local candidate="$2"

    [[ ! -e "$STATE_DIR" ]] || return 1
    mv -- "$candidate" "$STATE_DIR" || return 1
    if ! "$KERNEL_ENTRIES" sync --esp "$(dirname -- "$config")" \
        --state "$STATE_DIR" --variant "$VARIANT"; then
        mv -- "$STATE_DIR" "$candidate" || true
        return 1
    fi
    return 0
}

install_action() {
    local supplied_archive="$1"
    local archive esp config work candidate config_hash

    archive="$(absolute_existing_file "$supplied_archive")"
    check_machine
    require_root install "$VARIANT" "$archive"

    for command in \
        awk cat chown cmp cpio date df diff find findmnt flock grep head iasl install \
        lsinitcpio mktemp od python3 realpath sha256sum stat sync tail tr uname \
        zgrep; do
        need_cmd "$command"
    done
    need_cmd limine-entry-tool

    acquire_lock
    check_install_preconditions
    [[ ! -e "$STATE_DIR" ]] \
        || die "Managed state already exists. Remove the entry before a fresh installation."
    [[ ! -e "$DROPIN" ]] \
        || die "The reserved legacy Limine drop-in already exists without managed state: $DROPIN"

    esp="$(find_esp)"
    config="$esp/limine.conf"
    config_contains_entry "$config" \
        && die "The reserved Limine entry name already exists without managed state: $ENTRY_NAME"

    work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
    candidate="$(mktemp -d /var/lib/.omen-acpi-override-state.XXXXXX)"
    arm_override_cleanup "$work" "$candidate"

    config_hash="$(sha256_file "$config")"
    prepare_candidate_state "$archive" "$esp" "$work" "$candidate"
    [[ "$(sha256_file "$config")" == "$config_hash" ]] \
        || die "Limine configuration changed during preparation; retry the installation."

    if ! commit_new_install "$config" "$candidate"; then
        die "The experimental entry could not be installed transactionally."
    fi
    candidate=""
    ACTION_CLEANUP_CANDIDATE=""
    sync

    safe_remove_temp_dir "$work"
    work=""
    ACTION_CLEANUP_WORK=""
    disarm_override_cleanup

    log "Installation completed."
    log "Installed variant: $VARIANT ($EXPECTED_PATCHED_REVISION)"
    log "The normal CachyOS entry was not replaced."
    log "Per-kernel Limine entries were synchronized for linux-cachyos and linux-cachyos-lts."
    log "Do not make the experimental entry the default."
    log "Run refresh after a kernel/initramfs or Limine update; setup/update also performs this migration."
}

# Refresh, diagnostics and removal actions

refresh_action() {
    local esp config work backup stored_machine current_machine rc=0

    require_root refresh "$VARIANT"
    for command in \
        awk cat cmp cpio findmnt flock grep head install lsinitcpio mktemp \
        python3 realpath sha256sum stat sync tr; do
        need_cmd "$command"
    done
    [[ -x "$KERNEL_ENTRIES" ]] \
        || die "Multi-kernel entry manager not found: $KERNEL_ENTRIES"
    acquire_lock
    if [[ ! -d "$STATE_DIR" ]]; then
        log "Nothing is installed for $VARIANT."
        return 0
    fi
    verify_state_identity
    read_machine
    current_machine="$MACHINE_PRODUCT"$'\t'"$MACHINE_BOARD"$'\t'"$MACHINE_BIOS"
    if stored_machine="$(state_machine 2>/dev/null)"; then
        [[ "$stored_machine" == "$current_machine" ]] \
            || die "Managed AML belongs to a different machine or BIOS; refresh is blocked."
    else
        machine_is_reference \
            || die "Historical managed state without machine identity can only be refreshed on the validated reference."
    fi
    esp="$(find_esp)"
    config="$esp/limine.conf"

    if [[ -f "$STATE_DIR/kernel-entries.json" && ! -L "$STATE_DIR/kernel-entries.json" ]]; then
        "$KERNEL_ENTRIES" sync --esp "$esp" --state "$STATE_DIR" --variant "$VARIANT"
        log "The $VARIANT entries now match every installed supported CachyOS kernel."
        return 0
    fi

    legacy_state_metadata >/dev/null 2>&1 \
        && die "The pre-managed legacy $VARIANT format cannot be migrated without weakening its ownership checks; remove it normally, then install again."
    managed_state_valid \
        || die "The existing $VARIANT state is incomplete, modified or unsafe."
    verify_owned_dropin
    safe_root_regular_file "$STATE_DIR/kernel.img" \
        && safe_root_regular_file "$STATE_DIR/initramfs.img" \
        && [[ "$(sha256_file "$STATE_DIR/kernel.img")" == "$(<"$STATE_DIR/kernel.sha256")" ]] \
        && [[ "$(sha256_file "$STATE_DIR/initramfs.img")" == "$(<"$STATE_DIR/initramfs.sha256")" ]] \
        || die "The previous single-kernel payload state is incomplete or modified."
    config_contains_entry "$config" \
        || die "The previous single-kernel Limine entry is missing or ambiguous."

    work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
    trap 'safe_remove_temp_dir "${work:-}"' EXIT
    backup="$work/limine.conf.before-refresh"
    cp -a "$config" "$backup"
    build_early_initramfs "$STATE_DIR/DSDT.aml" "$work" "$work/early.cpio"
    install -o root -g root -m 0600 "$work/early.cpio" "$STATE_DIR/early.cpio"
    sha256_file "$STATE_DIR/early.cpio" > "$STATE_DIR/early.sha256"

    if ! limine-entry-tool --remove-kernel "$ENTRY_NAME" --quiet \
        || config_contains_entry "$config" \
        || ! rm -f -- "$DROPIN"; then
        rollback_managed_removal "$config" "$backup" "$STATE_DIR" "$STATE_DIR" || true
        die "The previous single-kernel entry could not be detached for migration."
    fi
    if "$KERNEL_ENTRIES" sync --esp "$esp" --state "$STATE_DIR" --variant "$VARIANT"; then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        rm -f -- "$STATE_DIR/kernel-entries.json"
        rollback_managed_removal "$config" "$backup" "$STATE_DIR" "$STATE_DIR" || true
        die "Multi-kernel migration failed; the previous validated entry was restored when possible."
    fi

    rm -f -- \
        "$STATE_DIR/dropin.conf" "$STATE_DIR/dropin.sha256" \
        "$STATE_DIR/kernel.img" "$STATE_DIR/kernel.sha256" \
        "$STATE_DIR/initramfs.img" "$STATE_DIR/initramfs.sha256" \
        "$STATE_DIR/normal-assets.tsv" "$STATE_DIR/limine.conf.before"
    sync
    safe_remove_temp_dir "$work"
    work=""
    trap - EXIT
    log "Migrated $VARIANT from one frozen kernel snapshot to dynamic standard/LTS entries."
}

create_legacy_removal_backup() {
    local config="$1" work="$2" legacy_hash="$3"
    local backup_root="/var/lib/omen-acpi-legacy-backups"
    local stamp backup legacy_kernel legacy_initramfs

    LEGACY_BACKUP=""
    if [[ ! -e "$backup_root" && ! -L "$backup_root" ]]; then
        install -d -o root -g root -m 0700 "$backup_root" || return 1
    fi
    [[ -d "$backup_root" && ! -L "$backup_root" \
        && "$(stat -c '%u' -- "$backup_root")" == "0" \
        && "$(stat -c '%a' -- "$backup_root")" == "700" ]] \
        || die "The legacy backup root is unavailable or unsafe: $backup_root"

    stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
    backup="$backup_root/${VARIANT}-${stamp}-${legacy_hash:0:12}"
    [[ ! -e "$backup" && ! -L "$backup" ]] \
        || die "Legacy removal-backup destination already exists: $backup"
    install -d -o root -g root -m 0700 "$backup" || return 1

    legacy_kernel="$(<"$work/legacy-kernel.path")" || return 1
    legacy_initramfs="$(<"$work/legacy-initramfs.path")" || return 1
    install -o root -g root -m 0600 -- "$config" "$backup/limine.conf.before-removal" || return 1
    install -o root -g root -m 0600 -- "$DROPIN" "$backup/dropin.conf" || return 1
    install -o root -g root -m 0600 -- "$legacy_kernel" "$backup/kernel.img" || return 1
    install -o root -g root -m 0600 -- "$legacy_initramfs" "$backup/initramfs.img" || return 1
    {
        printf 'OMEN ACPI Toolkit legacy removal rollback backup\n'
        printf 'Variant: %s\n' "$VARIANT"
        printf 'Legacy DSDT SHA-256: %s\n' "$legacy_hash"
        printf 'Created: %s\n' "$stamp"
        printf '\nThe state/ directory is the original pre-v2.1.1 state.\n'
        printf 'The other files can recreate the legacy test entry only if removal rollback is needed.\n'
        printf 'The normal Limine entry was never replaced.\n'
    } > "$backup/README.txt" || return 1
    chmod 0600 "$backup/README.txt" || return 1
    (
        cd "$backup"
        sha256sum -- \
            README.txt \
            dropin.conf \
            initramfs.img \
            kernel.img \
            limine.conf.before-removal \
            > RECOVERY-SHA256SUMS
    ) || return 1
    chmod 0600 "$backup/RECOVERY-SHA256SUMS" || return 1
    LEGACY_BACKUP="$backup"
}

rollback_legacy_removal() {
    local config="$1" backup="$2" work="$3" state_staged="$4"
    local failed=0 entry_count

    warn "Legacy removal failed; attempting to recreate the validated entry."
    entry_count="$(config_entry_count "$config" 2>/dev/null || printf invalid)"
    if [[ "$entry_count" != "0" ]]; then
        limine-entry-tool --remove-kernel "$ENTRY_NAME" --quiet >/dev/null 2>&1 \
            || failed=1
    fi

    install -o root -g root -m 0644 "$backup/dropin.conf" "$DROPIN" \
        || failed=1
    if ! limine-entry-tool --add-kernel \
        "$ENTRY_NAME" \
        "$backup/initramfs.img" \
        "$backup/kernel.img" \
        --comment "LEGACY RECOVERY: HP OMEN F.13 ${VARIANT} DSDT; normal entry unchanged" \
        --quiet; then
        failed=1
    fi

    if [[ "$state_staged" == "1" ]]; then
        if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" && -d "$backup/state" ]]; then
            mv -- "$backup/state" "$STATE_DIR" || failed=1
        else
            failed=1
        fi
    fi

    if ! config_contains_entry "$config"; then
        failed=1
    fi
    if ! extract_normal_entry "$config" "$work/normal-entry-rollback.txt" \
        || ! cmp -s "$work/normal-entry.txt" "$work/normal-entry-rollback.txt"; then
        failed=1
    fi
    if (( ! failed )) \
        && ! (validate_legacy_installation "$(dirname -- "$config")" "$work") >/dev/null 2>&1; then
        failed=1
    fi
    sync || failed=1

    if (( failed )); then
        warn "Automatic legacy rollback was incomplete."
        warn "Removal rollback material is preserved at: $backup"
        warn "Boot only the normal Limine entry until the configuration is repaired."
        return 1
    fi
    warn "The validated legacy entry was restored. Removal backup remains at: $backup"
    return 0
}

rollback_managed_removal() {
    local config="$1"
    local config_backup="$2"
    local candidate="$3"
    local previous_state="${4:-$STATE_DIR}"
    local failed=0

    warn "Managed removal failed; attempting to recreate the entry."
    limine-entry-tool --remove-kernel "$ENTRY_NAME" --quiet >/dev/null 2>&1 || true

    install_dropin "$previous_state/dropin.conf" || failed=1
    if ! limine-entry-tool --add-kernel \
        "$ENTRY_NAME" \
        "$previous_state/initramfs.img" \
        "$previous_state/kernel.img" \
        --comment "EXPERIMENTAL: HP OMEN F.13 ${VARIANT} DSDT; normal entry unchanged" \
        --quiet; then
        failed=1
    fi

    if (( failed )) || ! config_contains_entry "$config"; then
        cp -a "$config_backup" "$config" || true
        sync
        warn "The previous entry could not be recreated reliably. Existing state remains at $previous_state."
        warn "Managed state remains at $candidate. Boot the normal CachyOS entry."
        return 1
    fi

    if ! sync; then
        warn "The previous entry was recreated, but filesystem synchronization failed."
        return 1
    fi
    return 0
}

active_dsdt_report() {
    local state_aml="${1:-}"
    local expected_revision="$2"

    python3 - "$state_aml" "$expected_revision" <<'PY'
from pathlib import Path
import hashlib
import struct
import sys

active_path = Path("/sys/firmware/acpi/tables/DSDT")
stored_path = Path(sys.argv[1]) if sys.argv[1] else None
expected_revision = int(sys.argv[2], 0)
try:
    data = active_path.read_bytes()
except OSError:
    print("Active DSDT: unavailable")
    raise SystemExit(0)
if len(data) < 36:
    print("Active DSDT: invalid short table")
    raise SystemExit(0)

signature = data[0:4].decode("ascii", "replace")
oem_id = data[10:16].decode("ascii", "replace")
table_id = data[16:24].decode("ascii", "replace")
revision = struct.unpack_from("<I", data, 24)[0]
digest = hashlib.sha256(data).hexdigest()
print(
    f"Active DSDT: signature={signature}, OEM={oem_id!r}, "
    f"table={table_id!r}, revision=0x{revision:08X}"
)
print(f"Active DSDT SHA-256: {digest}")

if stored_path and stored_path.is_file():
    stored_digest = hashlib.sha256(stored_path.read_bytes()).hexdigest()
    print(f"Stored DSDT SHA-256: {stored_digest}")
    if digest == stored_digest:
        print("Override state: ACTIVE (active table matches the managed AML)")
    elif revision == expected_revision:
        print("Override state: UNKNOWN (revision matches, content hash does not)")
    else:
        print("Override state: NOT ACTIVE in this boot")
PY
}

kernel_message_report() {
    local active_matches_managed="$1" revision_hex kernel_messages wmi_errors

    log ""
    log "Relevant kernel messages:"
    revision_hex="${EXPECTED_PATCHED_REVISION#0x}"
    dmesg 2>/dev/null \
        | grep -Ei "ACPI.*(override|upgrade)|Override.*DSDT|DSDT.*${revision_hex}|taint" \
        | tail -n 30 || true

    [[ "$VARIANT" == "combined" ]] || return 0
    log ""
    log "Combined-variant BF01 error check:"
    if (( ! active_matches_managed )); then
        log "NOT EVALUATED: the managed combined DSDT is not active in this boot"
    elif ! kernel_messages="$(dmesg 2>/dev/null)"; then
        log "UNKNOWN: kernel messages could not be read"
        return 3
    else
        wmi_errors="$(grep -Ei 'AE_AML_BUFFER_LIMIT|WQBZ|WQBE' <<<"$kernel_messages" || true)"
        if [[ -n "$wmi_errors" ]]; then
            printf '%s\n' "$wmi_errors" | tail -n 30
            log "FAILED: related firmware errors are present in this boot"
            return 3
        fi
        log "PASS: no related firmware error is present in this boot"
    fi
}

status_action() {
    local esp config work current_assets stale=0
    local managed_dsdt_hash='' managed_dsdt_path='' kernel_status=0
    local active_matches_managed=0 stored_machine current_machine

    require_root status "$VARIANT"
    for command in \
        awk cat cmp dmesg findmnt flock grep head install lsinitcpio mktemp od python3 \
        realpath sha256sum stat tail tr uname; do
        need_cmd "$command"
    done
    [[ -x "$KERNEL_ENTRIES" ]] \
        || die "Multi-kernel entry manager not found: $KERNEL_ENTRIES"

    acquire_lock
    read_machine
    if machine_is_reference; then
        check_hybrid_graphics
        log "Machine: validated reference"
    else
        log "Machine: UNVALIDATED"
    fi

    log "Manager version: $VERSION"
    log "Variant: $VARIANT"
    log "Secure Boot: $(secure_boot_state)"

    if [[ ! -d "$STATE_DIR" ]]; then
        log "Managed installation: not installed"
        active_dsdt_report "" "$EXPECTED_PATCHED_REVISION"
        return 0
    fi

    if [[ -f "$STATE_DIR/kernel-entries.json" && ! -L "$STATE_DIR/kernel-entries.json" ]]; then
        verify_state_identity
        esp="$(find_esp)"
        log "Managed installation: multi-kernel"
        log "EFI system partition: $esp"
        if "$KERNEL_ENTRIES" status --esp "$esp" --state "$STATE_DIR" --variant "$VARIANT"; then
            kernel_status=0
        else
            kernel_status=$?
        fi
        active_dsdt_report "$STATE_DIR/DSDT.aml" "$EXPECTED_PATCHED_REVISION"
        if [[ -f /sys/firmware/acpi/tables/DSDT ]] \
            && cmp -s /sys/firmware/acpi/tables/DSDT "$STATE_DIR/DSDT.aml"; then
            active_matches_managed=1
        fi
        kernel_message_report "$active_matches_managed" || kernel_status=3
        return "$kernel_status"
    fi

    if legacy_state_metadata >/dev/null 2>&1; then
        esp="$(find_esp)"
        work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
        trap 'safe_remove_temp_dir "${work:-}"' EXIT
        validate_legacy_installation "$esp" "$work"
        log "Installation format: LEGACY (remove before fresh installation)"
        log "Legacy state integrity: valid"
        log "Limine entry: present and bound to the recorded legacy initramfs"
        log "Legacy command-line drop-in: present and unchanged"
        active_dsdt_report "$STATE_DIR/$LEGACY_AML_NAME" "$EXPECTED_PATCHED_REVISION"
        log ""
        log "Legacy payloads may contain an older kernel or initramfs."
        log "Remove this entry, then install a fresh managed entry from the normal CachyOS boot."
        safe_remove_temp_dir "$work"
        work=""
        trap - EXIT
        return 0
    fi

    verify_state_identity
    current_machine="$MACHINE_PRODUCT"$'\t'"$MACHINE_BOARD"$'\t'"$MACHINE_BIOS"
    if stored_machine="$(state_machine 2>/dev/null)"; then
        if [[ "$stored_machine" == "$current_machine" ]]; then
            log "Stored machine identity: current"
        else
            log "Stored machine identity: DIFFERENT MACHINE OR BIOS"
            stale=1
        fi
    elif machine_is_reference; then
        log "Stored machine identity: historical reference format"
    else
        log "Stored machine identity: HISTORICAL REFERENCE FORMAT IS NOT USABLE HERE"
        stale=1
    fi

    esp="$(find_esp)"
    config="$esp/limine.conf"
    log "Managed installation: present"
    log "EFI system partition: $esp"

    if config_contains_entry "$config"; then
        log "Limine entry: present"
    else
        log "Limine entry: MISSING"
        stale=1
    fi

    if [[ -f "$DROPIN" && -f "$STATE_DIR/dropin.sha256" ]] \
        && [[ "$(sha256_file "$DROPIN")" == "$(<"$STATE_DIR/dropin.sha256")" ]]; then
        log "Managed command-line drop-in: present and unchanged"
    else
        log "Managed command-line drop-in: MISSING OR MODIFIED"
        stale=1
    fi

    if stored_source_archive_valid; then
        log "Stored source build archive: valid"
    elif [[ -e "$STATE_DIR/source-build.tar.gz" || -e "$STATE_DIR/source-build.sha256" ]]; then
        log "Stored source build archive: CORRUPT OR INCOMPLETE"
        log "Remove and freshly install this entry before using it again."
        stale=1
    else
        log "Stored source build archive: MISSING"
        log "Remove and freshly install this entry before using it again."
        stale=1
    fi

    if [[ -f "$STATE_DIR/DSDT.aml" && ! -L "$STATE_DIR/DSDT.aml" \
        && -f "$STATE_DIR/DSDT.sha256" && ! -L "$STATE_DIR/DSDT.sha256" ]]; then
        managed_dsdt_hash="$(tr -d '[:space:]' < "$STATE_DIR/DSDT.sha256")"
    fi
    if [[ "$managed_dsdt_hash" =~ ^[0-9a-f]{64}$ \
        && "$(sha256_file "$STATE_DIR/DSDT.aml")" == "$managed_dsdt_hash" ]]; then
        managed_dsdt_path="$STATE_DIR/DSDT.aml"
        log "Managed DSDT integrity: valid"
    else
        log "Managed DSDT integrity: INVALID"
        stale=1
    fi

    work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
    trap 'safe_remove_temp_dir "${work:-}"' EXIT

    if load_normal_entry "$esp" "$work/normal-entry.txt"; then
        current_assets="$work/normal-assets.tsv"
        write_normal_assets "$current_assets"
        if cmp -s "$STATE_DIR/normal-assets.tsv" "$current_assets"; then
            log "Stored kernel/initramfs snapshot: CURRENT"
        else
            log "Stored kernel/initramfs snapshot: STALE"
            log "Remove and freshly install the experimental entry before booting it again."
            stale=1
        fi
    else
        log "Stored kernel/initramfs snapshot: UNKNOWN (normal entry could not be read)"
        stale=1
    fi

    if [[ -f "$STATE_DIR/kernel.img" && -f "$STATE_DIR/kernel.sha256" ]] \
        && [[ "$(sha256_file "$STATE_DIR/kernel.img")" == "$(<"$STATE_DIR/kernel.sha256")" ]]; then
        log "Stored kernel file integrity: valid"
    else
        log "Stored kernel file integrity: INVALID"
        stale=1
    fi

    if [[ -f "$STATE_DIR/initramfs.img" && -f "$STATE_DIR/initramfs.sha256" ]] \
        && [[ "$(sha256_file "$STATE_DIR/initramfs.img")" == "$(<"$STATE_DIR/initramfs.sha256")" ]]; then
        log "Stored initramfs file integrity: valid"
    else
        log "Stored initramfs file integrity: INVALID"
        stale=1
    fi

    active_dsdt_report "$managed_dsdt_path" "$EXPECTED_PATCHED_REVISION"
    if [[ -n "$managed_dsdt_path" && -f /sys/firmware/acpi/tables/DSDT ]] \
        && cmp -s /sys/firmware/acpi/tables/DSDT "$managed_dsdt_path"; then
        active_matches_managed=1
    fi

    kernel_message_report "$active_matches_managed" || stale=1

    if (( stale )); then
        safe_remove_temp_dir "$work"
        work=""
        trap - EXIT
        return 3
    fi
    safe_remove_temp_dir "$work"
    work=""
    trap - EXIT
    return 0
}

inspect_action() {
    local schema="conflict" esp config work entry_count output rc=0

    require_root inspect "$VARIANT"
    for command in awk findmnt flock grep head install lsinitcpio mktemp python3 realpath sha256sum stat tr; do
        need_cmd "$command"
    done

    acquire_lock
    if ! esp="$(find_esp 2>/dev/null)"; then
        printf 'SCHEMA=conflict\n'
        return 3
    fi
    config="$esp/limine.conf"
    entry_count="$(config_entry_count "$config" 2>/dev/null || printf invalid)"

    if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
        if output="$("$KERNEL_ENTRIES" status --esp "$esp" --variant "$VARIANT" 2>/dev/null)"; then
            rc=0
        else
            rc=$?
        fi
        if [[ ! -e "$DROPIN" && ! -L "$DROPIN" \
            && "$rc" == "0" && "$output" == *$'VARIANT\t'"$VARIANT"$'\tabsent'* ]]; then
            schema="absent"
        fi
    elif managed_state_valid; then
        if [[ -f "$STATE_DIR/kernel-entries.json" && ! -L "$STATE_DIR/kernel-entries.json" ]]; then
            if output="$("$KERNEL_ENTRIES" status --esp "$esp" --state "$STATE_DIR" --variant "$VARIANT" 2>/dev/null)"; then
                rc=0
            else
                rc=$?
            fi
            if (( rc == 0 || rc == 3 )) \
                && grep -Eq $'^VARIANT\t'"$VARIANT"$'\t(current|stale)$' <<<"$output"; then
                schema="managed"
            fi
        elif [[ -f "$DROPIN" && ! -L "$DROPIN" \
            && -f "$STATE_DIR/dropin.sha256" && ! -L "$STATE_DIR/dropin.sha256" \
            && "$(sha256_file "$DROPIN")" == "$(tr -d '[:space:]' < "$STATE_DIR/dropin.sha256")" \
            && "$entry_count" == "1" ]]; then
            schema="managed"
        fi
    elif legacy_state_metadata >/dev/null 2>&1 \
        && [[ ! -e "$STATE_DIR/dropin.before" && ! -L "$STATE_DIR/dropin.before" ]]; then
        work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
        trap 'safe_remove_temp_dir "${work:-}"' EXIT
        if (validate_legacy_installation "$esp" "$work") >/dev/null 2>&1; then
            schema="legacy"
        fi
        safe_remove_temp_dir "$work"
        work=""
        trap - EXIT
    fi

    printf 'SCHEMA=%s\n' "$schema"
    if [[ "$schema" == "conflict" ]]; then
        reason="$(awk -F '\t' -v variant="$VARIANT" \
            '$1 == "VARIANT" && $2 == variant && $3 == "conflict" { print $4; exit }' \
            <<<"${output:-}")"
        [[ -z "$reason" ]] || printf 'REASON=%s\n' "$reason"
        return 3
    fi
}

remove_legacy_action() {
    local esp config work legacy_hash backup state_staged=0

    legacy_hash="$(legacy_state_hash)" \
        || die "The existing $VARIANT state is not an exact supported legacy installation."
    esp="$(find_esp)"
    config="$esp/limine.conf"
    work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
    trap 'safe_remove_temp_dir "${work:-}"' EXIT
    validate_legacy_installation "$esp" "$work"
    create_legacy_removal_backup "$config" "$work" "$legacy_hash" \
        || die "Could not create the root-only legacy removal backup."
    backup="$LEGACY_BACKUP"

    if ! mv -- "$STATE_DIR" "$backup/state"; then
        die "Could not stage the legacy state in its recovery directory."
    fi
    state_staged=1
    if ! limine-entry-tool --remove-kernel "$ENTRY_NAME" --quiet \
        || [[ "$(config_entry_count "$config" 2>/dev/null || printf invalid)" != "0" ]]; then
        rollback_legacy_removal "$config" "$backup" "$work" "$state_staged" || true
        die "The legacy entry could not be removed safely."
    fi
    if ! cmp -s "$DROPIN" "$backup/dropin.conf"; then
        rollback_legacy_removal "$config" "$backup" "$work" "$state_staged" || true
        die "The legacy drop-in changed during removal."
    fi
    if [[ -f "$backup/state/dropin.before" ]]; then
        if ! install -o root -g root -m 0644 \
            "$backup/state/dropin.before" "$DROPIN"; then
            rollback_legacy_removal "$config" "$backup" "$work" "$state_staged" || true
            die "The pre-legacy drop-in could not be restored."
        fi
    elif ! rm -f -- "$DROPIN"; then
        rollback_legacy_removal "$config" "$backup" "$work" "$state_staged" || true
        die "The legacy drop-in could not be removed."
    fi
    if ! extract_normal_entry "$config" "$work/normal-entry-after-remove.txt" \
        || ! cmp -s "$work/normal-entry.txt" "$work/normal-entry-after-remove.txt"; then
        rollback_legacy_removal "$config" "$backup" "$work" "$state_staged" || true
        die "The normal Limine entry changed during legacy removal."
    fi
    sync

    safe_remove_temp_dir "$work"
    work=""
    trap - EXIT
    log "The validated legacy $VARIANT entry was removed."
    log "Removal backup retained at: $backup"
    log "The normal CachyOS entry was not modified."
}

remove_action() {
    local esp config work config_backup removed_state output rc=0

    require_root remove "$VARIANT"
    for command in awk cmp date findmnt flock grep head install lsinitcpio mktemp python3 realpath sha256sum stat sync tr; do
        need_cmd "$command"
    done
    need_cmd limine-entry-tool

    acquire_lock

    if [[ ! -d "$STATE_DIR" ]]; then
        if [[ -e "$DROPIN" ]]; then
            die "Reserved drop-in exists without ownership state; refusing to remove it: $DROPIN"
        fi
        esp="$(find_esp)"
        config="$esp/limine.conf"
        config_contains_entry "$config" \
            && die "Reserved Limine entry exists without ownership state; refusing to remove it."
        if output="$("$KERNEL_ENTRIES" status --esp "$esp" --variant "$VARIANT" 2>/dev/null)"; then
            rc=0
        else
            rc=$?
        fi
        (( rc == 0 )) \
            || die "A reserved multi-kernel entry exists without ownership state; refusing to remove it."
        log "Nothing is installed."
        return 0
    fi

    if legacy_state_metadata >/dev/null 2>&1; then
        remove_legacy_action
        return 0
    fi

    verify_state_identity
    [[ -r "$STATE_DIR/esp-path.txt" ]] || die "Managed state is missing esp-path.txt."
    esp="$(realpath -- "$(<"$STATE_DIR/esp-path.txt")")"
    [[ -f "$esp/limine.conf" ]] || die "Stored Limine configuration is unavailable: $esp/limine.conf"
    config="$esp/limine.conf"

    if [[ -f "$STATE_DIR/kernel-entries.json" && ! -L "$STATE_DIR/kernel-entries.json" ]]; then
        removed_state="${STATE_DIR}.removed.$$.tmp"
        [[ ! -e "$removed_state" ]] \
            || die "Unexpected removed-state path already exists: $removed_state"
        mv -- "$STATE_DIR" "$removed_state" \
            || die "Managed state could not be staged for removal: $STATE_DIR"
        if ! "$KERNEL_ENTRIES" remove --esp "$esp" --state "$removed_state" --variant "$VARIANT"; then
            mv -- "$removed_state" "$STATE_DIR" \
                || warn "Removal failed and managed state remains detached at: $removed_state"
            die "The multi-kernel entries could not be removed safely."
        fi
        rm -rf -- "$removed_state" \
            || warn "Entries were removed, but detached state remains at: $removed_state"
        sync
        log "The managed $VARIANT entries for all CachyOS kernels were removed."
        log "Every stock CachyOS entry was preserved."
        return 0
    fi

    verify_owned_dropin

    work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
    trap 'safe_remove_temp_dir "${work:-}"' EXIT
    config_backup="$work/limine.conf.before-remove"
    cp -a "$config" "$config_backup"

    if ! limine-entry-tool --remove-kernel "$ENTRY_NAME" --quiet; then
        rollback_managed_removal "$config" "$config_backup" "$STATE_DIR" "$STATE_DIR" || true
        die "limine-entry-tool could not remove the entry. Managed state was preserved."
    fi
    if config_contains_entry "$config"; then
        rollback_managed_removal "$config" "$config_backup" "$STATE_DIR" "$STATE_DIR" || true
        die "The Limine entry remains after removal. Managed state was preserved."
    fi

    if ! rm -f -- "$DROPIN" || [[ -e "$DROPIN" ]]; then
        rollback_managed_removal "$config" "$config_backup" "$STATE_DIR" "$STATE_DIR" || true
        die "Could not remove the managed drop-in. State was preserved."
    fi

    removed_state="${STATE_DIR}.removed.$$.tmp"
    if [[ -e "$removed_state" ]] || ! mv -- "$STATE_DIR" "$removed_state"; then
        rollback_managed_removal "$config" "$config_backup" "$STATE_DIR" "$STATE_DIR" || true
        die "Could not commit state removal; the managed entry was restored when possible."
    fi
    if ! rm -rf -- "$removed_state"; then
        warn "The boot entry was removed, but old private state remains at: $removed_state"
    fi
    sync

    safe_remove_temp_dir "$work"
    work=""
    trap - EXIT

    log "The managed $VARIANT experimental entry and its owned files were removed."
    log "The normal CachyOS entry was not modified."
}

stock_entry_action() {
    local esp work

    require_root stock-entry
    for command in awk cat findmnt flock grep head install lsinitcpio mktemp python3 realpath stat; do
        need_cmd "$command"
    done
    acquire_lock
    read_machine
    esp="$(find_esp)"
    work="$(mktemp -d /var/tmp/omen-acpi-override.XXXXXX)"
    trap 'safe_remove_temp_dir "${work:-}"' EXIT

    load_normal_entry "$esp" "$work/normal-entry.txt"
    check_source_initramfs
    printf '%s\n' "$NORMAL_TITLE"

    safe_remove_temp_dir "$work"
    work=""
    trap - EXIT
}

pre_uninstall_check_action() {
    local esp config entry_name recovery_payload

    require_root pre-uninstall-check
    for command in findmnt flock grep head install python3 readlink realpath stat; do
        need_cmd "$command"
    done

    acquire_lock
    esp="$(find_esp)"
    config="$esp/limine.conf"
    [[ -f "$config" && ! -L "$config" ]] \
        || die "Limine configuration is not a normal file: $config"

    recovery_payload="$esp/omen-acpi-stock-recovery"
    if [[ -e "$recovery_payload" || -L "$recovery_payload" ]]; then
        die "Incomplete stock-recovery state: the ESP payload still exists at $recovery_payload. Inspect or restore the managed recovery state; uninstall will not delete it implicitly."
    fi

    if [[ -e "$esp/omen-acpi" || -L "$esp/omen-acpi" ]]; then
        die "Managed multi-kernel payloads still exist at $esp/omen-acpi. Remove every variant before uninstall."
    fi

    local reserved_titles=(
        "zz-omen-acpi-s5-test"
        "zz-omen-acpi-s5-test-lts"
        "zz-omen-acpi-combined-test"
        "zz-omen-acpi-combined-test-lts"
        "zz-omen-acpi-stock-recovery"
        "zz-OMEN ACPI S5"
        "zz-OMEN ACPI S5 LTS"
        "zz-OMEN ACPI Combined"
        "zz-OMEN ACPI Combined LTS"
        "zz-OMEN ACPI stock recovery"
    )
    local entry_name
    for entry_name in "${reserved_titles[@]}"; do
        if grep -Eq -- "^[[:space:]]*/+\\+?${entry_name}[[:space:]]*$" "$config"; then
            die "Reserved Limine entry is still present: $entry_name"
        fi
    done

    log "Pre-uninstall check passed: all reserved Limine entry names are absent."
}

# Command-line entry point

main() {
    local action="${1:-help}"

    case "$action" in
        install)
            (($# == 3)) || die "Usage: $0 install VARIANT BUILD_ARCHIVE"
            select_variant "$2"
            install_action "$3"
            ;;
        refresh)
            (($# == 2)) || die "Usage: $0 refresh VARIANT"
            select_variant "$2"
            refresh_action
            ;;
        migrate|restore-legacy)
            die "This state-conversion action was removed."
            ;;
        status)
            (($# == 2)) || die "Usage: $0 status VARIANT"
            select_variant "$2"
            status_action
            ;;
        inspect)
            (($# == 2)) || die "Usage: $0 inspect VARIANT"
            select_variant "$2"
            inspect_action
            ;;
        remove)
            (($# == 2)) || die "Usage: $0 remove VARIANT"
            select_variant "$2"
            remove_action
            ;;
        stock-entry)
            (($# == 1)) || die "Usage: $0 stock-entry"
            stock_entry_action
            ;;
        pre-uninstall-check)
            (($# == 1)) || die "Usage: $0 pre-uninstall-check"
            pre_uninstall_check_action
            ;;
        help|-h|--help)
            (($# <= 1)) || die "Usage: $0 help"
            usage
            ;;
        *)
            usage >&2
            die "Unknown action: $action"
            ;;
    esac
}

main "$@"
