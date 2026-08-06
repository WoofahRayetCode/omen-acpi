#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

# Builds but does not install one of two DSDT override variants for:
#   DMI product: OMEN Gaming Laptop 16-ap0xxx
#   mainboard:   8E35
#   BIOS:        F.13
#
# Both variants extend _PTS(5) so that it sets PEGP.OMPR=3, then calls the
# firmware's original PEGP._PS3 method. This is intentionally identical to the
# original machine-tested installers. The "combined" variant also
# bounds the two affected WQBZ loops to the size of BF01; the "s5" variant
# leaves those loops byte-for-byte unchanged.

EXPECTED_PRODUCT="OMEN Gaming Laptop 16-ap0xxx"
EXPECTED_BOARD="8E35"
EXPECTED_BIOS="F.13"
ORIGINAL_OEM_REVISION="0x01072009"
ORIGINAL_DSDT_SHA256=""
MACHINE_PRODUCT=""
MACHINE_BOARD=""
MACHINE_BIOS=""
PACKAGE_FORMAT=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

usage() {
    printf 'Usage: %s VARIANT SOURCE_ARCHIVE\n' "$0"
    printf '\n'
    printf 'VARIANT must be one of:\n'
    printf '  s5        Build only the tested S5 power-off patch (OEM revision 0x0107200A).\n'
    printf '  combined  Build the S5 patch plus the WQBZ bounds fix (OEM revision 0x0107200B).\n'
    printf '\n'
    printf 'SOURCE_ARCHIVE must be an archive created by 01-collect-acpi.sh.\n'
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

safe_extract() {
    local archive="$1"
    local destination="$2"

    # Reject path traversal, links and special files before invoking tar. The
    # source package produced by 01-collect-acpi.sh contains only directories
    # and regular files, so no other archive member type is needed here.
    python3 - "$archive" <<'PY'
from pathlib import PurePosixPath
import sys
import tarfile

archive_path = sys.argv[1]

try:
    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = archive.getmembers()
except (OSError, tarfile.TarError) as exc:
    raise SystemExit(f"Cannot read source archive: {exc}")

if not members:
    raise SystemExit("Source archive is empty")
if len(members) > 32:
    raise SystemExit(f"Source archive has too many members: {len(members)}")
if sum(member.size for member in members if member.isfile()) > 32 * 1024 * 1024:
    raise SystemExit("Source archive exceeds the 32 MiB uncompressed safety limit")

normalized_names = [str(PurePosixPath(member.name)) for member in members]
if len(normalized_names) != len(set(normalized_names)):
    raise SystemExit("Source archive contains duplicate normalized paths")

for member in members:
    name = member.name
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"Unsafe archive member path: {name!r}")
    if not (member.isdir() or member.isfile()):
        raise SystemExit(f"Unsupported archive member type: {name!r}")
PY

    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$destination"
}

verify_source_checksums() {
    local checksum_file="$1"

    # Constrain checksum paths to the three files emitted by the collector so
    # sha256sum cannot be directed outside the extracted package directory.
    python3 - "$checksum_file" <<'PY'
from pathlib import Path, PurePosixPath
import re
import sys

checksum_path = Path(sys.argv[1])
expected_names = {"README.txt", "SOURCE.txt", "dsdt.dsl"}
found_names = []

for line_number, line in enumerate(
    checksum_path.read_text(encoding="utf-8", errors="strict").splitlines(), 1
):
    match = re.fullmatch(r"([0-9A-Fa-f]{64}) ([ *])(.+)", line)
    if match is None:
        raise SystemExit(f"Malformed SHA256SUMS line {line_number}")
    name = match.group(3)
    path = PurePosixPath(name)
    if path.is_absolute() or len(path.parts) != 1 or ".." in path.parts:
        raise SystemExit(f"Unsafe checksum path on line {line_number}: {name!r}")
    found_names.append(name)

if len(found_names) != len(set(found_names)):
    raise SystemExit("SHA256SUMS contains duplicate file names")
if set(found_names) != expected_names:
    raise SystemExit(
        "SHA256SUMS must cover exactly README.txt, SOURCE.txt and dsdt.dsl"
    )
PY

    (
        cd "$(dirname "$checksum_file")"
        sha256sum --check --strict SHA256SUMS >/dev/null
    ) || die "Source archive content checksum verification failed"
}

read_source_fingerprint() {
    local source_info="$1"

    python3 - "$source_info" "$MACHINE_PRODUCT" "$MACHINE_BOARD" "$MACHINE_BIOS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
machine = tuple(sys.argv[2:5])
reference = ("OMEN Gaming Laptop 16-ap0xxx", "8E35", "F.13")
metadata = {}
for line_number, line in enumerate(
    path.read_text(encoding="utf-8", errors="strict").splitlines(), 1
):
    if not line or "=" not in line:
        raise SystemExit(f"Malformed SOURCE.txt line {line_number}")
    key, value = line.split("=", 1)
    if not key or key in metadata:
        raise SystemExit(f"Duplicate or empty SOURCE.txt key on line {line_number}")
    metadata[key] = value

expected = {
    "PACKAGE_FORMAT": "2" if machine == reference else "3",
    "DMI_PRODUCT": machine[0],
    "MAINBOARD": machine[1],
    "BIOS": machine[2],
    "ORIGINAL_DSDT_OEM_REVISION": "0x01072009",
}
expected_keys = set(expected) | {"ORIGINAL_DSDT_SHA256"}
if set(metadata) != expected_keys:
    missing = sorted(expected_keys - set(metadata))
    extra = sorted(set(metadata) - expected_keys)
    raise SystemExit(
        f"Unexpected SOURCE.txt keys; missing={missing}, extra={extra}"
    )
for key, expected_value in expected.items():
    if metadata[key] != expected_value:
        raise SystemExit(
            f"SOURCE.txt mismatch for {key}: expected {expected_value!r}, "
            f"found {metadata[key]!r}"
        )

fingerprint = metadata["ORIGINAL_DSDT_SHA256"]
if re.fullmatch(r"[0-9a-f]{64}", fingerprint) is None:
    raise SystemExit("SOURCE.txt contains an invalid original DSDT fingerprint")
print(fingerprint)
PY
}

verify_aml_header() {
    local aml="$1"

    python3 - "$aml" "$PATCHED_OEM_REVISION" <<'PY'
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
expected_revision = int(sys.argv[2], 16)
data = path.read_bytes()

if len(data) < 36:
    raise SystemExit("AML file is shorter than the ACPI header")

signature = data[0:4]
length = struct.unpack_from("<I", data, 4)[0]
oem_id = data[10:16].decode("ascii", "strict")
oem_table_id = data[16:24].decode("ascii", "strict")
oem_revision = struct.unpack_from("<I", data, 24)[0]

if signature != b"DSDT":
    raise SystemExit(f"Unexpected ACPI signature: {signature!r}")
if length != len(data):
    raise SystemExit(f"ACPI header length {length} differs from file length {len(data)}")
if sum(data) & 0xFF:
    raise SystemExit("Invalid ACPI checksum")
if oem_id != "HPQOEM":
    raise SystemExit(f"Unexpected OEM ID: {oem_id!r}")
if oem_table_id != "8E35    ":
    raise SystemExit(f"Unexpected OEM table ID: {oem_table_id!r}")
if oem_revision != expected_revision:
    raise SystemExit(
        f"Unexpected OEM revision: 0x{oem_revision:08X}; "
        f"expected 0x{expected_revision:08X}"
    )

print(
    f"Verified DSDT: {len(data)} bytes, OEM revision 0x{oem_revision:08X}",
    file=sys.stderr,
)
PY
}

verify_roundtrip_semantics() {
    local roundtrip_dsl="$1"

    python3 - "$roundtrip_dsl" "$variant" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
variant = sys.argv[2]
text = path.read_text(encoding="utf-8", errors="strict")

if variant not in {"s5", "combined"}:
    raise SystemExit(f"Unsupported verification variant: {variant!r}")

def method_block_span(source_text: str, method_name: str) -> tuple[int, int]:
    matches = list(
        re.finditer(
            rf"(?m)^\s*Method\s*\(\s*{re.escape(method_name)}\s*,",
            source_text,
        )
    )
    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one {method_name} method; found {len(matches)}"
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

pts_start, pts_end = method_block_span(text, "_PTS")
pts = text[pts_start:pts_end]
s5_guard = "If (LEqual (Arg0, 0x05))"
guard_count = pts.count(s5_guard)
if guard_count != 1:
    raise SystemExit(
        f"Expected one S5 guard inside _PTS; found {guard_count}"
    )

critical_markers = [
    r"Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)",
    r"\_SB.PCI0.GPP0.PEGP._PS3 ()",
]

positions = [pts.index(s5_guard)]
for marker in critical_markers:
    count = text.count(marker)
    if count != 1:
        raise SystemExit(f"Expected one round-trip marker {marker!r}; found {count}")
    local_count = pts.count(marker)
    if local_count != 1:
        raise SystemExit(
            f"Expected round-trip marker {marker!r} once inside _PTS; "
            f"found {local_count}"
        )
    positions.append(pts.index(marker))

if positions != sorted(positions):
    raise SystemExit("S5 round-trip operations are not in the required order")

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
original_count = normalized_text.count(normalize_whitespace(original_loop))
bounded_count = normalized_text.count(normalize_whitespace(bounded_loop))

if variant == "s5":
    if original_count != 2 or bounded_count != 0:
        raise SystemExit(
            "S5 round trip must contain exactly two original WQBZ loops and "
            f"no bounded loops; found original={original_count}, bounded={bounded_count}"
        )
else:
    if original_count != 0 or bounded_count != 2:
        raise SystemExit(
            "Combined round trip must contain exactly two bounded WQBZ loops and "
            f"no original loops; found original={original_count}, bounded={bounded_count}"
        )
PY
}

if (($# == 1)) && [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (($# != 2)); then
    usage >&2
    exit 2
fi

variant="$1"
source_archive="$2"

case "$variant" in
    s5)
        PATCHED_OEM_REVISION="0x0107200A"
        PATCH_ID="S5_ONLY"
        PATCH_SUFFIX="S5"
        WQBZ_WORKAROUND="NO"
        ;;
    combined)
        PATCHED_OEM_REVISION="0x0107200B"
        PATCH_ID="S5_AND_WQBZ"
        PATCH_SUFFIX="COMBINED"
        WQBZ_WORKAROUND="YES"
        ;;
    *)
        usage >&2
        die "Unknown variant '$variant'; expected 's5' or 'combined'"
        ;;
esac

for command in python3 tar iasl diff sha256sum realpath find mktemp install; do
    need_cmd "$command"
done

check_machine

[[ -f "$source_archive" ]] || die "Archive not found: $source_archive"
source_archive="$(realpath "$source_archive")"

stamp="$(date +%Y%m%d-%H%M%S)"
temp_base="${TMPDIR:-/tmp}"
work="$(mktemp -d "$temp_base/omen-dsdt-work.XXXXXX")"

cleanup() {
    if [[ -n "${work:-}" && -d "$work" ]]; then
        case "$(basename -- "$work")" in
            omen-dsdt-work.*)
                rm -rf -- "$work"
                ;;
        esac
    fi
}
trap cleanup EXIT

extract_dir="$work/extracted"
build_dir="$work/build"
package_root="$work/package"
if [[ "$PACKAGE_FORMAT" == "2" ]]; then
    package_name="omen-dsdt-f13-${variant}-build-$stamp"
else
    package_name="omen-dsdt-unvalidated-${variant}-build-$stamp"
fi
package_dir="$package_root/$package_name"
output_dir="${OMEN_ACPI_OUTPUT_DIR:-${HOME:?HOME is not set}}"
[[ -d "$output_dir" ]] || die "Output directory does not exist: $output_dir"
output_dir="$(realpath -- "$output_dir")"
result="$output_dir/$package_name.tar.gz"

patched_basename="DSDT-OMEN-F13-$PATCH_SUFFIX"
patched_dsl_name="$patched_basename.dsl"
patched_patch_name="$patched_basename.patch"

mkdir -p "$extract_dir" "$build_dir" "$package_dir"
safe_extract "$source_archive" "$extract_dir"

mapfile -t checksum_files < <(find "$extract_dir" -type f -name SHA256SUMS -print)
((${#checksum_files[@]} == 1)) \
    || die "Expected one SHA256SUMS file in the source archive; found ${#checksum_files[@]}"
verify_source_checksums "${checksum_files[0]}"

mapfile -t source_files < <(find "$extract_dir" -type f -name dsdt.dsl -print)
((${#source_files[@]} == 1)) \
    || die "Expected one dsdt.dsl in the source archive; found ${#source_files[@]}"

mapfile -t source_info_files < <(find "$extract_dir" -type f -name SOURCE.txt -print)
((${#source_info_files[@]} == 1)) \
    || die "Expected one SOURCE.txt in the source archive; found ${#source_info_files[@]}"

source_package_dir="$(dirname -- "${checksum_files[0]}")"
[[ "${source_files[0]}" == "$source_package_dir/dsdt.dsl" \
    && "${source_info_files[0]}" == "$source_package_dir/SOURCE.txt" ]] \
    || die "The source files and SHA256SUMS are not in one package directory"

if ! ORIGINAL_DSDT_SHA256="$(read_source_fingerprint "${source_info_files[0]}")"; then
    die "Source archive metadata verification failed"
fi

install -m 0600 "${source_files[0]}" "$build_dir/DSDT-original.dsl"

python3 - \
    "$build_dir/DSDT-original.dsl" \
    "$build_dir/$patched_dsl_name" \
    "$variant" \
    "$PATCHED_OEM_REVISION" <<'PY'
from pathlib import Path
import re
import sys

source_path = Path(sys.argv[1])
destination_path = Path(sys.argv[2])
variant = sys.argv[3]
patched_revision = sys.argv[4]

if variant not in {"s5", "combined"}:
    raise SystemExit(f"Unsupported build variant: {variant!r}")
if patched_revision not in {"0x0107200A", "0x0107200B"}:
    raise SystemExit(f"Unsupported patched OEM revision: {patched_revision!r}")
if (variant, patched_revision) not in {
    ("s5", "0x0107200A"),
    ("combined", "0x0107200B"),
}:
    raise SystemExit("Build variant and OEM revision do not match")

text = source_path.read_text(encoding="utf-8", errors="strict")

header_old = 'DefinitionBlock ("", "DSDT", 2, "HPQOEM", "8E35    ", 0x01072009)'
header_new = (
    'DefinitionBlock ("", "DSDT", 2, "HPQOEM", "8E35    ", '
    f'{patched_revision})'
)

count = text.count(header_old)
if count != 1:
    raise SystemExit(f"Expected one original DSDT header; found {count}")
if header_new in text:
    raise SystemExit("The source already carries the patched OEM revision")
text = text.replace(header_old, header_new, 1)

external_anchor = "    External (_SB_.PCI0.GPP0.PEGP, DeviceObj)\n"
external_insert = (
    external_anchor
    + "    External (_SB_.PCI0.GPP0.PEGP.OMPR, IntObj)\n"
    + "    External (_SB_.PCI0.GPP0.PEGP._PS3, MethodObj)    // 0 Arguments\n"
)

count = text.count(external_anchor)
if count != 1:
    raise SystemExit(f"Expected one PEGP external declaration; found {count}")
if "External (_SB_.PCI0.GPP0.PEGP.OMPR," in text:
    raise SystemExit("OMPR external declaration is already present")
if "External (_SB_.PCI0.GPP0.PEGP._PS3," in text:
    raise SystemExit("_PS3 external declaration is already present")
text = text.replace(external_anchor, external_insert, 1)

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

count = text.count(pts_old)
if count != 1:
    raise SystemExit(f"Expected one original _PTS method; found {count}")
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
            f"Expected exactly one {method_name} method; found {len(matches)}"
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
        f"Expected exactly two original WQBZ loops inside WQBZ; found {old_count}"
    )
if bounded_count != 0 or loop_new in text:
    raise SystemExit("Source DSDT unexpectedly contains a bounded WQBZ loop")

if variant == "combined":
    patched_wqbz = wqbz.replace(loop_old, loop_new)
    text = text[:wqbz_start] + patched_wqbz + text[wqbz_end:]
    if text.count(loop_old) != 0 or patched_wqbz.count(loop_new) != 2:
        raise SystemExit("The two WQBZ loop replacements did not apply exactly")
else:
    if text.count(loop_old) != 2 or text.count(loop_new) != 0:
        raise SystemExit("The S5-only variant changed the WQBZ loops unexpectedly")

destination_path.write_text(text, encoding="utf-8")
PY

if diff -u \
    --label DSDT-original.dsl \
    --label "$patched_dsl_name" \
    "$build_dir/DSDT-original.dsl" \
    "$build_dir/$patched_dsl_name" \
    > "$build_dir/$patched_patch_name"; then
    die "The deterministic patch is unexpectedly empty"
else
    diff_status=$?
    ((diff_status == 1)) || die "diff failed with status $diff_status"
fi

printf 'Compiling the %s DSDT variant...\n' "$variant"
(
    cd "$build_dir"
    iasl -tc "$patched_dsl_name" > compile.log 2>&1
) || {
    sed -n '1,240p' "$build_dir/compile.log" >&2
    die "DSDT compilation failed"
}

compiled_aml="$build_dir/$patched_basename.aml"
[[ -s "$compiled_aml" ]] || die "iASL did not create the expected AML file"
install -m 0600 "$compiled_aml" "$build_dir/DSDT.aml"
verify_aml_header "$build_dir/DSDT.aml"

mkdir -p "$build_dir/roundtrip"
install -m 0600 "$build_dir/DSDT.aml" "$build_dir/roundtrip/DSDT.aml"
(
    cd "$build_dir/roundtrip"
    iasl -dl -d DSDT.aml > roundtrip.log 2>&1
) || {
    sed -n '1,240p' "$build_dir/roundtrip/roundtrip.log" >&2
    die "AML-to-ASL round trip failed"
}

roundtrip_dsl="$build_dir/roundtrip/DSDT.dsl"
[[ -s "$roundtrip_dsl" ]] || die "Round trip did not produce DSDT.dsl"
verify_roundtrip_semantics "$roundtrip_dsl"

install -m 0600 "$build_dir/DSDT-original.dsl" "$package_dir/DSDT-original.dsl"
install -m 0600 "$build_dir/$patched_dsl_name" "$package_dir/$patched_dsl_name"
install -m 0600 "$build_dir/$patched_patch_name" "$package_dir/$patched_patch_name"
install -m 0600 "$build_dir/DSDT.aml" "$package_dir/DSDT.aml"
install -m 0600 "$build_dir/compile.log" "$package_dir/compile.log"
install -m 0600 "$roundtrip_dsl" "$package_dir/DSDT-roundtrip.dsl"

{
    printf 'PACKAGE_FORMAT=%s\n' "$PACKAGE_FORMAT"
    printf 'VARIANT=%s\n' "$variant"
    printf 'PATCH=%s\n' "$PATCH_ID"
    printf 'WQBZ_WORKAROUND=%s\n' "$WQBZ_WORKAROUND"
    printf 'DMI_PRODUCT=%s\n' "$MACHINE_PRODUCT"
    printf 'MAINBOARD=%s\n' "$MACHINE_BOARD"
    printf 'BIOS=%s\n' "$MACHINE_BIOS"
    printf 'ORIGINAL_DSDT_OEM_REVISION=%s\n' "$ORIGINAL_OEM_REVISION"
    printf 'ORIGINAL_DSDT_SHA256=%s\n' "$ORIGINAL_DSDT_SHA256"
    printf 'PATCHED_DSDT_OEM_REVISION=%s\n' "$PATCHED_OEM_REVISION"
    printf 'BUILD_KERNEL=%s\n' "$(uname -r)"
} > "$package_dir/BUILD-INFO.txt"

{
    printf 'This private build archive contains an original decompiled DSDT, a deterministic patch, the patched source and the verified AML.\n'
    printf 'Nothing was installed while creating this archive.\n'
    printf 'The S5 patch runs only in _PTS(5) and performs PEGP.OMPR=3 followed by PEGP._PS3(), matching the original machine-tested installers.\n'
    if [[ "$variant" == "combined" ]]; then
        printf 'This combined variant also bounds exactly two WQBZ loops to SizeOf(BF01) and stops each loop at the first zero byte.\n'
    else
        printf 'This S5-only variant leaves both original WQBZ loops unchanged.\n'
    fi
    printf 'Treat this machine-derived archive as private unless you have manually reviewed it.\n'
} > "$package_dir/README-BUILD.txt"

(
    cd "$package_dir"
    sha256sum \
        BUILD-INFO.txt \
        README-BUILD.txt \
        DSDT-original.dsl \
        "$patched_dsl_name" \
        "$patched_patch_name" \
        DSDT.aml \
        DSDT-roundtrip.dsl \
        compile.log \
        > SHA256SUMS
)

tar -czf "$result" -C "$package_root" "$package_name"
chmod 0600 "$result"

if [[ -n "${OMEN_ACPI_RESULT_FILE:-}" ]]; then
    printf '%s\n' "$result" > "$OMEN_ACPI_RESULT_FILE"
    chmod 0600 "$OMEN_ACPI_RESULT_FILE"
fi

printf '\nBuild completed and verified. Nothing was installed.\n'
printf 'Variant: %s\n' "$variant"
printf 'Build archive:\n%s\n' "$result"
printf '\nKeep this generated archive private unless you have manually reviewed its contents.\n'
