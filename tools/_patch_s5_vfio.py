#!/usr/bin/env python3
# One-shot local helper to add experimental s5-vfio variant.
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PTS_S5 = r'''    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep
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

PTS_VFIO = r'''    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep
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
             * Experimental VFIO/Looking Glass path: arm NVDE before the
             * firmware's original discrete-GPU power-down sequence so
             * PG00._OFF() is reachable without host nvidia.ko.
             */
            If (LEqual (Arg0, 0x05))
            {
                If (CondRefOf (\_SB.PCI0.GPP0.PEGP.OMPR))
                {
                    If (CondRefOf (\_SB.PCI0.GPP0.PEGP._PS3))
                    {
                        Store (One, NVDE)
                        Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)
                        \_SB.PCI0.GPP0.PEGP._PS3 ()
                    }
                }
            }
        }
    }
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 occurrence, found {count}")
    return text.replace(old, new, 1)


def patch_pts_assignment(body: str) -> str:
    marker = "pts_new = r'''"
    start = body.index(marker)
    end = body.index("'''\n", start + len(marker)) + len("'''\n")
    old = body[start:end]
    if "Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)" not in old:
        raise SystemExit("pts_new does not look like the S5 body")
    if "Store (One, NVDE)" in old:
        raise SystemExit("pts_new already contains NVDE")
    replacement = (
        "pts_new_s5 = r'''"
        + PTS_S5
        + "'''\n"
        + "pts_new_vfio = r'''"
        + PTS_VFIO
        + "'''\n"
        + "if variant == \"s5-vfio\":\n"
        + "    pts_new = pts_new_vfio\n"
        + "else:\n"
        + "    pts_new = pts_new_s5\n"
    )
    return body[:start] + replacement + body[end:]


def patch_required_once(body: str) -> str:
    # In the shell sources, Python string literals contain \\_SB (two backslashes).
    old = (
        'required_once = (\n'
        '    "If (CondRefOf (\\\\_SB.PCI0.GPP0.PEGP.OMPR))",\n'
        '    "If (CondRefOf (\\\\_SB.PCI0.GPP0.PEGP._PS3))",\n'
        '    "Store (0x03, \\\\_SB.PCI0.GPP0.PEGP.OMPR)",\n'
        '    "\\\\_SB.PCI0.GPP0.PEGP._PS3 ()",\n'
        ')\n'
        'for fragment in required_once:\n'
        '    if text.count(fragment) != 1:\n'
        '        raise SystemExit(f"patched fragment is absent or ambiguous: {fragment}")\n'
    )
    new = (
        'required_once = [\n'
        '    "If (CondRefOf (\\\\_SB.PCI0.GPP0.PEGP.OMPR))",\n'
        '    "If (CondRefOf (\\\\_SB.PCI0.GPP0.PEGP._PS3))",\n'
        '    "Store (0x03, \\\\_SB.PCI0.GPP0.PEGP.OMPR)",\n'
        '    "\\\\_SB.PCI0.GPP0.PEGP._PS3 ()",\n'
        ']\n'
        'if variant == "s5-vfio":\n'
        '    required_once.insert(2, "Store (One, NVDE)")\n'
        'elif "Store (One, NVDE)" in text:\n'
        '    raise SystemExit("non-VFIO variant unexpectedly writes NVDE")\n'
        'for fragment in required_once:\n'
        '    if text.count(fragment) != 1:\n'
        '        raise SystemExit(f"patched fragment is absent or ambiguous: {fragment}")\n'
    )
    if old in body:
        return replace_once(body, old, new, "required_once")
    raise SystemExit("required_once block not found")


def patch_transform_body(body: str) -> str:
    body = body.replace(
        'if variant not in {"s5", "combined"}:',
        'if variant not in {"s5", "combined", "s5-vfio"}:',
    )
    body = body.replace(
        'if patched_revision not in {"0x0107200A", "0x0107200B"}:',
        'if patched_revision not in {"0x0107200A", "0x0107200B", "0x0107200C"}:',
    )
    body = body.replace(
        'if revision not in {"0x0107200A", "0x0107200B"}:',
        'if revision not in {"0x0107200A", "0x0107200B", "0x0107200C"}:',
    )
    body = body.replace(
        '''if (variant, patched_revision) not in {
    ("s5", "0x0107200A"),
    ("combined", "0x0107200B"),
}:''',
        '''if (variant, patched_revision) not in {
    ("s5", "0x0107200A"),
    ("combined", "0x0107200B"),
    ("s5-vfio", "0x0107200C"),
}:''',
    )
    body = patch_pts_assignment(body)
    body = body.replace(
        'raise SystemExit("the S5-only variant changed the WQBZ loops unexpectedly")',
        'raise SystemExit("the S5-only/s5-vfio variant changed the WQBZ loops unexpectedly")',
    )
    body = body.replace(
        'raise SystemExit("The S5-only variant changed the WQBZ loops unexpectedly")',
        'raise SystemExit("The S5-only/s5-vfio variant changed the WQBZ loops unexpectedly")',
    )
    if "required_once = (" in body:
        body = patch_required_once(body)
    else:
        # Builder transform has no required_once tuple; inject NVDE assertions
        # immediately before writing the destination.
        write_marker = None
        for candidate in (
            "destination_path.write_text(text, encoding=\"utf-8\")",
            "destination.write_text(text, encoding=\"utf-8\")",
        ):
            if candidate in body:
                write_marker = candidate
                break
        if write_marker is None:
            raise SystemExit("transform write_text marker not found")
        injection = '''if variant == "s5-vfio":
    if text.count("Store (One, NVDE)") != 1:
        raise SystemExit("s5-vfio variant must write NVDE exactly once")
elif "Store (One, NVDE)" in text:
    raise SystemExit("non-VFIO variant unexpectedly writes NVDE")

'''
        body = body.replace(write_marker, injection + write_marker, 1)
    return body


def patch_roundtrip_body(body: str, *, pts_var: str) -> str:
    body = body.replace(
        'if variant not in {"s5", "combined"}:',
        'if variant not in {"s5", "combined", "s5-vfio"}:',
    )

    list_markers = f'''if variant == "s5-vfio":
    critical_markers = [
        r"Store (One, NVDE)",
        r"Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)",
        r"\\_SB.PCI0.GPP0.PEGP._PS3 ()",
    ]
else:
    critical_markers = [
        r"Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)",
        r"\\_SB.PCI0.GPP0.PEGP._PS3 ()",
    ]
    if "Store (One, NVDE)" in {pts_var}:
        raise SystemExit("non-VFIO round trip unexpectedly writes NVDE")
'''
    old_list = '''critical_markers = [
    r"Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)",
    r"\\_SB.PCI0.GPP0.PEGP._PS3 ()",
]
'''
    old_tuple = '''critical_markers = (
    r"Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)",
    r"\\_SB.PCI0.GPP0.PEGP._PS3 ()",
)
'''
    if old_list in body:
        body = replace_once(body, old_list, list_markers, "critical_markers-list")
    elif old_tuple in body:
        body = replace_once(body, old_tuple, list_markers, "critical_markers-tuple")
    else:
        raise SystemExit("critical_markers block not found")

    body = body.replace(
        'raise SystemExit("S5 round-trip operations are not in the required order")',
        'raise SystemExit("S5 round-trip operations are not in the required NVDE/OMPR/_PS3 order")',
    )
    body = body.replace(
        'raise SystemExit("S5 operations are not ordered OMPR=3, _PS3")',
        'raise SystemExit("S5 operations are not ordered NVDE/OMPR/_PS3 as required")',
    )
    body = body.replace(
        'if variant == "s5":\n    if original_count != 2 or bounded_count != 0:',
        'if variant in {"s5", "s5-vfio"}:\n    if original_count != 2 or bounded_count != 0:',
    )
    body = body.replace(
        'if variant == "s5":\n    if (\n        global_original != 2',
        'if variant in {"s5", "s5-vfio"}:\n    if (\n        global_original != 2',
    )
    return body


def splice_python_heredoc(text: str, unique: str, patcher) -> str:
    idx = text.index(unique)
    start = text.rindex("<<'PY'\n", 0, idx) + len("<<'PY'\n")
    end = text.index("\nPY\n", start)
    body = text[start:end]
    return text[:start] + patcher(body) + text[end:]


def patch_builder() -> None:
    path = ROOT / "scripts/02-build-dsdt.sh"
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "printf '  s5        Build only the tested S5 power-off patch (OEM revision 0x0107200A).\\n'\n"
        "    printf '  combined  Build the S5 patch plus the WQBZ bounds fix (OEM revision 0x0107200B).\\n'\n",
        "printf '  s5        Build only the tested S5 power-off patch (OEM revision 0x0107200A).\\n'\n"
        "    printf '  combined  Build the S5 patch plus the WQBZ bounds fix (OEM revision 0x0107200B).\\n'\n"
        "    printf '  s5-vfio   Experimental S5 + NVDE=1 for VFIO/Looking Glass (OEM revision 0x0107200C).\\n'\n",
        "builder-usage",
    )
    text = replace_once(
        text,
        '''case "$variant" in
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
esac''',
        '''case "$variant" in
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
    s5-vfio)
        PATCHED_OEM_REVISION="0x0107200C"
        PATCH_ID="S5_VFIO_NVDE"
        PATCH_SUFFIX="S5-VFIO"
        WQBZ_WORKAROUND="NO"
        ;;
    *)
        usage >&2
        die "Unknown variant '$variant'; expected 's5', 'combined' or 's5-vfio'"
        ;;
esac''',
        "builder-case",
    )
    text = splice_python_heredoc(
        text,
        'source_path = Path(sys.argv[1])',
        patch_transform_body,
    )
    text = splice_python_heredoc(
        text,
        'Unsupported verification variant',
        lambda body: patch_roundtrip_body(body, pts_var="pts"),
    )
    # package notes
    text = text.replace(
        'printf \'This S5-only variant leaves both original WQBZ loops unchanged.\\n\'\n',
        'printf \'This S5-only variant leaves both original WQBZ loops unchanged.\\n\'\n'
        '    elif [[ "$variant" == "s5-vfio" ]]; then\n'
        '        printf \'This experimental s5-vfio variant writes NVDE=1 before OMPR/_PS3 and leaves WQBZ unchanged.\\n\'\n',
    )
    # The above may be wrong structurally; fix carefully below if needed.
    path.write_text(text, encoding="utf-8")


def patch_manager() -> None:
    path = ROOT / "scripts/03-manage-limine-entry.sh"
    text = path.read_text(encoding="utf-8")
    start = text.index("select_variant() {")
    end = text.index("\n}\n", start) + 3
    old_fn = text[start:end]
    if "s5-vfio" in old_fn:
        raise SystemExit("manager already patched")
    if "Expected 's5' or 'combined'." not in old_fn:
        raise SystemExit("unexpected select_variant")

    insert = '''        s5-vfio)
            ENTRY_NAME="zz-omen-acpi-s5-vfio-test"
            DROPIN="/etc/limine-entry-tool.d/92-omen-acpi-s5-vfio-test.conf"
            STATE_DIR="/var/lib/omen-acpi-s5-vfio-test"
            EXPECTED_PATCHED_REVISION="0x0107200C"
            LEGACY_AML_NAME="DSDT-s5-vfio-test.aml"
            LEGACY_DSL_NAME="DSDT-OMEN-F13-s5-vfio-test.dsl"
            LEGACY_BUILD_AML_NAME="DSDT-OMEN-F13-s5-vfio-test.aml"
            LEGACY_DROPIN_COMMENT="# Experimental VFIO/Looking Glass S5 NVDE arming test"
            LEGACY_ENTRY_COMMENT="EXPERIMENTAL: HP OMEN F.13 DSDT S5+NVDE for VFIO; stock unchanged"
            LEGACY_TEMP_PREFIX="omen-s5-vfio-test"
            LEGACY_COMPOSITE_NAME="initramfs-omen-acpi-s5-vfio-test.img"
            ;;
'''
    new_fn = old_fn.replace(
        "die \"Unknown variant '$VARIANT'. Expected 's5' or 'combined'.\"",
        "die \"Unknown variant '$VARIANT'. Expected 's5', 'combined' or 's5-vfio'.\"",
    )
    star = new_fn.rindex("        *)\n")
    new_fn = new_fn[:star] + insert + new_fn[star:]
    text = text[:start] + new_fn + text[end:]

    text = splice_python_heredoc(
        text,
        "unsupported variant: {variant!r}",
        patch_transform_body,
    )
    text = splice_python_heredoc(
        text,
        "round trip must contain exactly one S5 guard inside _PTS",
        lambda body: patch_roundtrip_body(body, pts_var="pts_text"),
    )

    # reserved titles in uninstall
    text = replace_once(
        text,
        '''    local reserved_titles=(
        "zz-omen-acpi-s5-test"
        "zz-omen-acpi-s5-test-lts"
        "zz-omen-acpi-combined-test"
        "zz-omen-acpi-combined-test-lts"
''',
        '''    local reserved_titles=(
        "zz-omen-acpi-s5-test"
        "zz-omen-acpi-s5-test-lts"
        "zz-omen-acpi-combined-test"
        "zz-omen-acpi-combined-test-lts"
        "zz-omen-acpi-s5-vfio-test"
        "zz-omen-acpi-s5-vfio-test-lts"
        "zz-OMEN ACPI S5 VFIO"
        "zz-OMEN ACPI S5 VFIO LTS"
''',
        "reserved-titles",
    )

    # usage snippet
    text = text.replace(
        "  s5        S5 power-off correction only\n"
        "  combined  S5 power-off correction plus the two confirmed BF01 loop bounds\n",
        "  s5        S5 power-off correction only\n"
        "  combined  S5 power-off correction plus the two confirmed BF01 loop bounds\n"
        "  s5-vfio   Experimental S5 + NVDE=1 for VFIO/Looking Glass hosts\n",
    )

    # WQBZ_WORKAROUND metadata
    text = text.replace(
        '"WQBZ_WORKAROUND": "YES" if expected_variant == "combined" else "NO",',
        '"WQBZ_WORKAROUND": "YES" if expected_variant == "combined" else "NO",',
    )

    path.write_text(text, encoding="utf-8")


def patch_kernel_entries() -> None:
    path = ROOT / "scripts/05-kernel-entries.py"
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '''CURRENT_TITLES = {
    "s5": {
        "linux-cachyos": "zz-OMEN ACPI S5",
        "linux-cachyos-lts": "zz-OMEN ACPI S5 LTS",
    },
    "combined": {
        "linux-cachyos": "zz-OMEN ACPI Combined",
        "linux-cachyos-lts": "zz-OMEN ACPI Combined LTS",
    },
}
LEGACY_TITLES = {
    "s5": {
        "linux-cachyos": "zz-omen-acpi-s5-test",
        "linux-cachyos-lts": "zz-omen-acpi-s5-test-lts",
    },
    "combined": {
        "linux-cachyos": "zz-omen-acpi-combined-test",
        "linux-cachyos-lts": "zz-omen-acpi-combined-test-lts",
    },
}
''',
        '''CURRENT_TITLES = {
    "s5": {
        "linux-cachyos": "zz-OMEN ACPI S5",
        "linux-cachyos-lts": "zz-OMEN ACPI S5 LTS",
    },
    "combined": {
        "linux-cachyos": "zz-OMEN ACPI Combined",
        "linux-cachyos-lts": "zz-OMEN ACPI Combined LTS",
    },
    "s5-vfio": {
        "linux-cachyos": "zz-OMEN ACPI S5 VFIO",
        "linux-cachyos-lts": "zz-OMEN ACPI S5 VFIO LTS",
    },
}
LEGACY_TITLES = {
    "s5": {
        "linux-cachyos": "zz-omen-acpi-s5-test",
        "linux-cachyos-lts": "zz-omen-acpi-s5-test-lts",
    },
    "combined": {
        "linux-cachyos": "zz-omen-acpi-combined-test",
        "linux-cachyos-lts": "zz-omen-acpi-combined-test-lts",
    },
    "s5-vfio": {
        "linux-cachyos": "zz-omen-acpi-s5-vfio-test",
        "linux-cachyos-lts": "zz-omen-acpi-s5-vfio-test-lts",
    },
}
''',
        "titles",
    )
    text = replace_once(
        text,
        '''def entry_comment(variant: str) -> str:
    if variant == "s5":
        return "Experimental S5 GPU power-off override. Stock CachyOS entry unchanged."
    if variant == "combined":
        return "Experimental S5 override plus WQBZ buffer bounds. Stock CachyOS entry unchanged."
    raise Failure(f"unsupported variant: {variant}")
''',
        '''def entry_comment(variant: str) -> str:
    if variant == "s5":
        return "Experimental S5 GPU power-off override. Stock CachyOS entry unchanged."
    if variant == "combined":
        return "Experimental S5 override plus WQBZ buffer bounds. Stock CachyOS entry unchanged."
    if variant == "s5-vfio":
        return "Experimental VFIO/Looking Glass S5 override (NVDE=1). Stock CachyOS entry unchanged."
    raise Failure(f"unsupported variant: {variant}")
''',
        "entry-comment",
    )
    text = text.replace(
        r'r"omen-acpi-owned=v1 variant=(s5|combined) kernel=(linux-cachyos(?:-lts)?)"',
        r'r"omen-acpi-owned=v1 variant=(s5|combined|s5-vfio) kernel=(linux-cachyos(?:-lts)?)"',
    )
    text = text.replace(
        r'r"omen-acpi-owned=v1 variant=(s5|combined) kernel=(linux-cachyos(?:-lts)?)"',
        r'r"omen-acpi-owned=v1 variant=(s5|combined|s5-vfio) kernel=(linux-cachyos(?:-lts)?)"',
    )
    # fullmatch form without r prefix maybe
    text = text.replace(
        'r"omen-acpi-owned=v1 variant=(s5|combined) kernel=(linux-cachyos(?:-lts)?)"',
        'r"omen-acpi-owned=v1 variant=(s5|combined|s5-vfio) kernel=(linux-cachyos(?:-lts)?)"',
    )
    text = text.replace(
        'parser.add_argument("--variant", choices=("s5", "combined"))',
        'parser.add_argument("--variant", choices=("s5", "combined", "s5-vfio"))',
    )
    # status loops over variants
    text = text.replace(
        'for variant in ("s5", "combined"):',
        'for variant in ("s5", "combined", "s5-vfio"):',
    )
    path.write_text(text, encoding="utf-8")


def patch_probe() -> None:
    path = ROOT / "scripts/00-probe-boot.sh"
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'readonly COMBINED_REVISION="0x0107200B"\n',
        'readonly COMBINED_REVISION="0x0107200B"\nreadonly S5_VFIO_REVISION="0x0107200C"\n',
        "probe-rev",
    )
    text = replace_once(
        text,
        '''managed_s5_state="$(root_path /var/lib/omen-acpi-s5-test)"
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
if [[ -n "$managed_s5_sha" && "$dsdt_sha256" == "$managed_s5_sha" ]] \\
    || [[ -n "$managed_combined_sha" && "$dsdt_sha256" == "$managed_combined_sha" ]]; then
    active_format="managed"
elif [[ -n "$legacy_s5_sha" && "$dsdt_sha256" == "$legacy_s5_sha" ]] \\
    || [[ -n "$legacy_combined_sha" && "$dsdt_sha256" == "$legacy_combined_sha" ]]; then
    active_format="legacy"
fi
''',
        '''managed_s5_state="$(root_path /var/lib/omen-acpi-s5-test)"
managed_combined_state="$(root_path /var/lib/omen-acpi-combined-test)"
managed_s5_vfio_state="$(root_path /var/lib/omen-acpi-s5-vfio-test)"
managed_s5_sha="$(validated_managed_hash "$managed_s5_state" s5 "$S5_REVISION" 2>/dev/null || true)"
managed_combined_sha="$(validated_managed_hash "$managed_combined_state" combined "$COMBINED_REVISION" 2>/dev/null || true)"
managed_s5_vfio_sha="$(validated_managed_hash "$managed_s5_vfio_state" s5-vfio "$S5_VFIO_REVISION" 2>/dev/null || true)"
legacy_s5_sha="$(validated_legacy_hash "$managed_s5_state" s5 "$S5_REVISION" 2>/dev/null || true)"
legacy_combined_sha="$(validated_legacy_hash "$managed_combined_state" combined "$COMBINED_REVISION" 2>/dev/null || true)"

s5_format="absent"
combined_format="absent"
s5_vfio_format="absent"
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
if [[ -n "$managed_s5_vfio_sha" ]]; then
    s5_vfio_format="managed"
elif [[ -e "$managed_s5_vfio_state" || -L "$managed_s5_vfio_state" ]]; then
    s5_vfio_format="conflict"
fi

active_format="none"
if [[ -n "$managed_s5_sha" && "$dsdt_sha256" == "$managed_s5_sha" ]] \\
    || [[ -n "$managed_combined_sha" && "$dsdt_sha256" == "$managed_combined_sha" ]] \\
    || [[ -n "$managed_s5_vfio_sha" && "$dsdt_sha256" == "$managed_s5_vfio_sha" ]]; then
    active_format="managed"
elif [[ -n "$legacy_s5_sha" && "$dsdt_sha256" == "$legacy_s5_sha" ]] \\
    || [[ -n "$legacy_combined_sha" && "$dsdt_sha256" == "$legacy_combined_sha" ]]; then
    active_format="legacy"
fi
''',
        "probe-state",
    )
    text = replace_once(
        text,
        '''            omen_acpi.variant=combined)
                ((boot_marker_count += 1))
                boot_marker="combined"
                ;;
            omen_acpi.variant=*)
''',
        '''            omen_acpi.variant=combined)
                ((boot_marker_count += 1))
                boot_marker="combined"
                ;;
            omen_acpi.variant=s5-vfio)
                ((boot_marker_count += 1))
                boot_marker="s5-vfio"
                ;;
            omen_acpi.variant=*)
''',
        "probe-marker",
    )

    # Classification: add s5-vfio managed match near s5/combined.
    # Find the s5 managed classification block and insert vfio after combined.
    needle = 'state="combined"\n'
    # We'll append a dedicated block after the combined managed block by unique context.
    old = '''    && "$boot_marker" != "s5" ]]; then
    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then
        state="unknown"
        reason="additional-acpi-override"
'''
    # Too fragile; instead patch env output and add classification with unique managed_combined block end.
    # Read classification section
    cls_start = text.index('elif [[ -n "$managed_combined_sha" && "$dsdt_sha256" == "$managed_combined_sha"')
    # Find following state=combined assignment area end at next elif/else
    # Insert a new elif before legacy checks.
    insert_at = text.index(
        'elif [[ -n "$legacy_s5_sha" && "$dsdt_sha256" == "$legacy_s5_sha"',
    )
    block = '''elif [[ -n "$managed_s5_vfio_sha" && "$dsdt_sha256" == "$managed_s5_vfio_sha" \\
    && "$dsdt_revision" == "$S5_VFIO_REVISION" \\
    && "$boot_marker" != "s5" && "$boot_marker" != "combined" ]]; then
    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then
        state="unknown"
        reason="additional-acpi-override"
    else
        state="s5-vfio"
        reason="managed-s5-vfio-hash"
        clean=1
    fi
'''
    text = text[:insert_at] + block + text[insert_at:]

    # Also tighten existing s5/combined boot_marker exclusions to include s5-vfio
    text = text.replace(
        '&& "$boot_marker" != "combined" ]]; then\n    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then\n        state="unknown"\n        reason="additional-acpi-override"',
        '&& "$boot_marker" != "combined" && "$boot_marker" != "s5-vfio" ]]; then\n    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then\n        state="unknown"\n        reason="additional-acpi-override"',
        1,
    )
    text = text.replace(
        '&& "$boot_marker" != "s5" ]]; then\n    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then\n        state="unknown"\n        reason="additional-acpi-override"',
        '&& "$boot_marker" != "s5" && "$boot_marker" != "s5-vfio" ]]; then\n    if [[ "$taint_acpi" == "1" || "$log_other_acpi" == "1" ]]; then\n        state="unknown"\n        reason="additional-acpi-override"',
        1,
    )

    # env output
    text = text.replace(
        'printf \'S5_FORMAT=%s\\n\' "$s5_format"\n',
        'printf \'S5_FORMAT=%s\\n\' "$s5_format"\nprintf \'S5_VFIO_FORMAT=%s\\n\' "$s5_vfio_format"\n',
    )
    text = text.replace(
        'printf \'COMBINED_FORMAT=%s\\n\' "$combined_format"\n',
        'printf \'COMBINED_FORMAT=%s\\n\' "$combined_format"\nprintf \'S5_VFIO_FORMAT=%s\\n\' "$s5_vfio_format"\n',
    )
    # Avoid duplicating S5_VFIO_FORMAT if both replacements hit; dedupe later if needed.

    path.write_text(text, encoding="utf-8")


def patch_cli() -> None:
    path = ROOT / "omen-acpi"
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'readonly COMBINED_BUILD_POINTER="$USER_STATE_ROOT/build-combined.path"\n',
        'readonly COMBINED_BUILD_POINTER="$USER_STATE_ROOT/build-combined.path"\n'
        'readonly S5_VFIO_BUILD_POINTER="$USER_STATE_ROOT/build-s5-vfio.path"\n',
        "cli-pointer",
    )

    def allow(old: str, new: str, label: str) -> None:
        nonlocal text
        text = replace_once(text, old, new, label)

    # Broad token expansions for command parsing / loops. Keep 'both' meaning s5+combined only.
    replacements = [
        (
            "stock|s5|combined|unknown|unsupported|unavailable)",
            "stock|s5|combined|s5-vfio|unknown|unsupported|unavailable)",
            "probe-state-case",
        ),
        (
            "s5|combined) printf '%s' \"$CYAN\" ;;",
            "s5|combined|s5-vfio) printf '%s' \"$CYAN\" ;;",
            "color",
        ),
        (
            "setup:s5|setup:combined|setup:both|build:s5|build:combined|build:both|install:s5|install:combined|install:both|collect:)",
            "setup:s5|setup:combined|setup:s5-vfio|setup:both|build:s5|build:combined|build:s5-vfio|build:both|install:s5|install:combined|install:s5-vfio|install:both|collect:)",
            "pending",
        ),
        (
            's5|combined) ;;',
            's5|combined|s5-vfio) ;;',
            "single-variant-case",
        ),
        (
            's5) printf \'%s\\n\' "$S5_BUILD_POINTER" ;;\n        combined) printf \'%s\\n\' "$COMBINED_BUILD_POINTER" ;;',
            's5) printf \'%s\\n\' "$S5_BUILD_POINTER" ;;\n        combined) printf \'%s\\n\' "$COMBINED_BUILD_POINTER" ;;\n        s5-vfio) printf \'%s\\n\' "$S5_VFIO_BUILD_POINTER" ;;',
            "build-pointer-for",
        ),
        (
            's5|combined|both|all) printf \'%s\\n\' "$1" ;;\n        *) die "Variant must be s5, combined or both." ;;',
            's5|combined|s5-vfio|both|all) printf \'%s\\n\' "$1" ;;\n        *) die "Variant must be s5, combined, s5-vfio or both." ;;',
            "normalize",
        ),
        (
            's5) printf \'%s\\n\' "$PROBE_S5_FORMAT" ;;\n        combined) printf \'%s\\n\' "$PROBE_COMBINED_FORMAT" ;;',
            's5) printf \'%s\\n\' "$PROBE_S5_FORMAT" ;;\n        combined) printf \'%s\\n\' "$PROBE_COMBINED_FORMAT" ;;\n        s5-vfio) printf \'%s\\n\' "$PROBE_S5_VFIO_FORMAT" ;;',
            "probe-format",
        ),
        (
            'for variant in s5 combined; do',
            'for variant in s5 combined s5-vfio; do',
            "inspect-loop",
        ),
        (
            'if [[ -n "$build_archive" && "$requested" != "s5" && "$requested" != "combined" ]]; then',
            'if [[ -n "$build_archive" && "$requested" != "s5" && "$requested" != "combined" && "$requested" != "s5-vfio" ]]; then',
            "explicit-archive",
        ),
    ]
    for old, new, label in replacements:
        if text.count(old) == 0:
            raise SystemExit(f"missing {label}: {old!r}")
        text = text.replace(old, new)

    # Probe env parsing
    text = text.replace(
        'PROBE_S5_FORMAT="unknown"\n',
        'PROBE_S5_FORMAT="unknown"\nPROBE_S5_VFIO_FORMAT="unknown"\n',
    )
    text = text.replace(
        'S5_FORMAT) PROBE_S5_FORMAT="$value" ;;\n',
        'S5_FORMAT) PROBE_S5_FORMAT="$value" ;;\n            S5_VFIO_FORMAT) PROBE_S5_VFIO_FORMAT="$value" ;;\n',
    )
    text = text.replace(
        'case "$PROBE_S5_FORMAT" in managed|legacy|conflict|absent) ;; *) PROBE_S5_FORMAT="unknown" ;; esac\n',
        'case "$PROBE_S5_FORMAT" in managed|legacy|conflict|absent) ;; *) PROBE_S5_FORMAT="unknown" ;; esac\n'
        '    case "$PROBE_S5_VFIO_FORMAT" in managed|legacy|conflict|absent) ;; *) PROBE_S5_VFIO_FORMAT="unknown" ;; esac\n',
    )

    # When inspecting schemas, update PROBE_S5_VFIO_FORMAT
    text = text.replace(
        '''                if [[ "$variant" == "s5" ]]; then
                    PROBE_S5_FORMAT="$schema"
''',
        '''                if [[ "$variant" == "s5" ]]; then
                    PROBE_S5_FORMAT="$schema"
                elif [[ "$variant" == "s5-vfio" ]]; then
                    PROBE_S5_VFIO_FORMAT="$schema"
''',
    )

    # build/install/remove/status switch arms: add s5-vfio beside s5|combined single arms
    text = text.replace("s5|combined)\n", "s5|combined|s5-vfio)\n")

    # doctor output
    text = text.replace(
        'printf \'S5 entry format: %s\\n\' "$PROBE_S5_FORMAT"\n',
        'printf \'S5 entry format: %s\\n\' "$PROBE_S5_FORMAT"\n'
        '    printf \'S5 VFIO entry format: %s\\n\' "$PROBE_S5_VFIO_FORMAT"\n',
    )

    # help text
    for old, new in [
        ("omen-acpi setup [s5|combined|both]", "omen-acpi setup [s5|combined|s5-vfio|both]"),
        ("omen-acpi build <s5|combined|both>", "omen-acpi build <s5|combined|s5-vfio|both>"),
        ("omen-acpi install <s5|combined|both>", "omen-acpi install <s5|combined|s5-vfio|both>"),
        ("omen-acpi refresh [s5|combined|all]", "omen-acpi refresh [s5|combined|s5-vfio|all]"),
        ("omen-acpi status [s5|combined|all]", "omen-acpi status [s5|combined|s5-vfio|all]"),
        ("omen-acpi remove <s5|combined|all>", "omen-acpi remove <s5|combined|s5-vfio|all>"),
        ("''|s5|combined|both)", "''|s5|combined|s5-vfio|both)"),
        ("s5|combined|both)", "s5|combined|s5-vfio|both)"),
        ("s5|combined|all)", "s5|combined|s5-vfio|all)"),
    ]:
        text = text.replace(old, new)

    # Conflict checks include vfio format
    text = text.replace(
        '"$PROBE_S5_FORMAT" == "conflict" || "$PROBE_COMBINED_FORMAT" == "conflict"',
        '"$PROBE_S5_FORMAT" == "conflict" || "$PROBE_COMBINED_FORMAT" == "conflict" || "$PROBE_S5_VFIO_FORMAT" == "conflict"',
    )
    text = text.replace(
        '"$PROBE_STATE" == "s5" || "$PROBE_STATE" == "combined"',
        '"$PROBE_STATE" == "s5" || "$PROBE_STATE" == "combined" || "$PROBE_STATE" == "s5-vfio"',
    )
    text = text.replace(
        '"$PROBE_S5_FORMAT" == "managed" || "$PROBE_COMBINED_FORMAT" == "managed"',
        '"$PROBE_S5_FORMAT" == "managed" || "$PROBE_COMBINED_FORMAT" == "managed" || "$PROBE_S5_VFIO_FORMAT" == "managed"',
    )

    path.write_text(text, encoding="utf-8")


def patch_tests() -> None:
    path = ROOT / "tests/test_transform.py"
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '''def verify_output(output: str, variant: str, revision: str) -> None:
    assert f\'"8E35    ", {revision})\' in output
    ompr = output.index("Store (0x03, \\\\_SB.PCI0.GPP0.PEGP.OMPR)")
    ps3 = output.index("\\\\_SB.PCI0.GPP0.PEGP._PS3 ()")
    assert ompr < ps3
    assert "Store (One, NVDE)" not in output
    assert "If (CondRefOf (NVDE))" not in output
    assert output.count("If (LEqual (Arg0, 0x05))") == 1
    if variant == "s5":
        assert output.count(ORIGINAL_LOOP) == 2
        assert output.count(BOUNDED_LOOP) == 0
    else:
        assert output.count(ORIGINAL_LOOP) == 0
        assert output.count(BOUNDED_LOOP) == 2
        assert output.count("Break") == 2
''',
        '''def verify_output(output: str, variant: str, revision: str) -> None:
    assert f\'"8E35    ", {revision})\' in output
    ompr = output.index("Store (0x03, \\\\_SB.PCI0.GPP0.PEGP.OMPR)")
    ps3 = output.index("\\\\_SB.PCI0.GPP0.PEGP._PS3 ()")
    assert ompr < ps3
    assert "If (CondRefOf (NVDE))" not in output
    assert output.count("If (LEqual (Arg0, 0x05))") == 1
    if variant == "s5-vfio":
        nvde = output.index("Store (One, NVDE)")
        assert nvde < ompr < ps3
        assert output.count(ORIGINAL_LOOP) == 2
        assert output.count(BOUNDED_LOOP) == 0
    else:
        assert "Store (One, NVDE)" not in output
        assert ompr < ps3
        if variant == "s5":
            assert output.count(ORIGINAL_LOOP) == 2
            assert output.count(BOUNDED_LOOP) == 0
        else:
            assert output.count(ORIGINAL_LOOP) == 0
            assert output.count(BOUNDED_LOOP) == 2
            assert output.count("Break") == 2
''',
        "verify_output",
    )
    text = replace_once(
        text,
        'revision = 0x0107200A if variant == "s5" else 0x0107200B',
        'revision = {"s5": 0x0107200A, "combined": 0x0107200B, "s5-vfio": 0x0107200C}[variant]',
        "manager-rev",
    )
    text = replace_once(
        text,
        'for variant, revision in (("s5", "0x0107200A"), ("combined", "0x0107200B")):',
        'for variant, revision in (("s5", "0x0107200A"), ("combined", "0x0107200B"), ("s5-vfio", "0x0107200C")):',
        "transform-loop",
    )
    text = text.replace(
        'if variant == "s5":\n            missing_original_loop = output.replace(ORIGINAL_LOOP_BLOCK, "", 1)',
        'if variant in {"s5", "s5-vfio"}:\n            missing_original_loop = output.replace(ORIGINAL_LOOP_BLOCK, "", 1)',
    )
    path.write_text(text, encoding="utf-8")


def patch_docs() -> None:
    path = ROOT / "patches/README.md"
    text = path.read_text(encoding="utf-8")
    if "s5-vfio" in text:
        return
    addition = '''

## `s5-vfio`: experimental VFIO / Looking Glass path

OEM revision: `0x0107200C`

This variant is for hosts that keep the discrete NVIDIA GPU permanently bound to
`vfio-pci` (Looking Glass / GPU passthrough). In that configuration the host
NVIDIA driver never runs, so it never arms `NVDE`, and the stock S5 sequence
reaches `PG00._OFF()` only to return immediately.

`s5-vfio` keeps the S5-only WQBZ behaviour and inserts one extra store before
`OMPR` / `_PS3`:

```asl
Store (One, NVDE)
Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)
\\_SB.PCI0.GPP0.PEGP._PS3 ()
```

It does not call `PG00._OFF()` directly, does not change suspend/runtime PM, and
does not claim to satisfy the second `_OFF` guard (`GSTA()`). Treat it as an
experimental Limine entry only.
'''
    path.write_text(text + addition, encoding="utf-8")


def fix_builder_notes() -> None:
    path = ROOT / "scripts/02-build-dsdt.sh"
    text = path.read_text(encoding="utf-8")
    # Repair a potentially broken elif insertion from earlier attempt.
    bad = (
        "printf 'This S5-only variant leaves both original WQBZ loops unchanged.\\n'\n"
        "    elif [[ \"$variant\" == \"s5-vfio\" ]]; then\n"
        "        printf 'This experimental s5-vfio variant writes NVDE=1 before OMPR/_PS3 and leaves WQBZ unchanged.\\n'\n"
    )
    if bad in text:
        # Find surrounding if/elif structure
        idx = text.index(bad)
        # Look back for if combined
        window = text[idx - 400 : idx + 400]
        raise SystemExit(f"builder notes need manual check:\n{window}")
    old = '''    if [[ "$variant" == "combined" ]]; then
        printf 'This combined variant also bounds exactly two WQBZ loops to SizeOf(BF01) and stops each loop at the first zero byte.\\n'
    else
        printf 'This S5-only variant leaves both original WQBZ loops unchanged.\\n'
    fi
'''
    new = '''    if [[ "$variant" == "combined" ]]; then
        printf 'This combined variant also bounds exactly two WQBZ loops to SizeOf(BF01) and stops each loop at the first zero byte.\\n'
    elif [[ "$variant" == "s5-vfio" ]]; then
        printf 'This experimental s5-vfio variant writes NVDE=1 before OMPR/_PS3 and leaves WQBZ unchanged.\\n'
    else
        printf 'This S5-only variant leaves both original WQBZ loops unchanged.\\n'
    fi
'''
    if old in text:
        text = replace_once(text, old, new, "builder-notes")
        path.write_text(text, encoding="utf-8")


def fix_manager_combined_temp_vars() -> None:
    """Ensure combined branch still has TEMP/COMPOSITE after our select_variant edit."""
    path = ROOT / "scripts/03-manage-limine-entry.sh"
    text = path.read_text(encoding="utf-8")
    start = text.index('select_variant() {')
    end = text.index('\n}\n', start) + 3
    fn = text[start:end]
    # If combined is missing LEGACY_TEMP_PREFIX, copy from original pattern.
    if 's5-vfio)' not in fn:
        raise SystemExit('s5-vfio missing from select_variant after patch')
    if 'LEGACY_TEMP_PREFIX="omen-s5-vfio-test"' not in fn:
        raise SystemExit('s5-vfio temp prefix missing')
    # combined should still define TEMP_PREFIX
    if 'LEGACY_TEMP_PREFIX="omen-combined-test"' not in fn:
        # Insert after combined DROPIN comment line if present
        needle = 'LEGACY_DROPIN_COMMENT="# Creato da install-omen-combined-limine-test.sh"\n'
        if needle not in fn:
            raise SystemExit('combined dropin comment missing')
        fn = fn.replace(
            needle,
            needle
            + '            LEGACY_TEMP_PREFIX="omen-combined-test"\n'
            + '            LEGACY_COMPOSITE_NAME="initramfs-omen-acpi-combined-test.img"\n',
            1,
        )
        text = text[:start] + fn + text[end:]
        path.write_text(text, encoding="utf-8")


def dedupe_probe_env() -> None:
    path = ROOT / "scripts/00-probe-boot.sh"
    text = path.read_text(encoding="utf-8")
    # If S5_VFIO_FORMAT printf duplicated, keep one near COMBINED_FORMAT only.
    lines = text.splitlines(keepends=True)
    seen = 0
    out = []
    for line in lines:
        if 'printf \'S5_VFIO_FORMAT=%s\\n\' "$s5_vfio_format"' in line:
            seen += 1
            if seen > 1:
                continue
        out.append(line)
    path.write_text(''.join(out), encoding='utf-8')


def main() -> None:
    import sys

    only = sys.argv[1:] or [
        "builder",
        "manager",
        "kernel",
        "probe",
        "cli",
        "tests",
        "docs",
    ]
    if "builder" in only:
        patch_builder()
        fix_builder_notes()
    if "manager" in only:
        patch_manager()
        fix_manager_combined_temp_vars()
    if "kernel" in only:
        patch_kernel_entries()
    if "probe" in only:
        patch_probe()
        dedupe_probe_env()
    if "cli" in only:
        patch_cli()
    if "tests" in only:
        patch_tests()
    if "docs" in only:
        patch_docs()
    print("patched s5-vfio support:", ", ".join(only))


if __name__ == "__main__":
    main()
