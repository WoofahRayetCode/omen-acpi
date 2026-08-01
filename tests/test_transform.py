#!/usr/bin/env python3
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Exercise both deterministic ASL transformers without distributing firmware."""

from __future__ import annotations

from pathlib import Path
import subprocess
import struct
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts" / "02-build-dsdt.sh"
MANAGER = ROOT / "scripts" / "03-manage-limine-entry.sh"

FIXTURE = r'''DefinitionBlock ("", "DSDT", 2, "HPQOEM", "8E35    ", 0x01072009)
{
    Name (NVDE, Zero)
    External (_SB_.PCI0.GPP0.PEGP, DeviceObj)

    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep
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

    Method (WQBZ, 3, Serialized)
    {
        If (One)
        {
                    While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))
                    {
                        Store (DerefOf (Index (BF01, Local5)), Local3)
                        Store (Local3, Index (N005, Local1))
                        Increment (Local5)
                        Increment (Local1)
                    }

                    While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))
                    {
                        Store (DerefOf (Index (BF01, Local5)), Local3)
                        Store (Local3, Index (N005, Local1))
                        Increment (Local5)
                        Increment (Local1)
                    }
        }
    }
}
'''

ORIGINAL_LOOP = "While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))"
BOUNDED_LOOP = "While (LLess (Local5, SizeOf (BF01)))"
ORIGINAL_LOOP_BLOCK = r'''                    While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))
                    {
                        Store (DerefOf (Index (BF01, Local5)), Local3)
                        Store (Local3, Index (N005, Local1))
                        Increment (Local5)
                        Increment (Local1)
                    }
'''


def extract_transform(path: Path, marker: str) -> str:
    text = path.read_text(encoding="utf-8")
    marker_position = text.index(marker)
    opener = text.index("<<'PY'\n", marker_position) + len("<<'PY'\n")
    closer = text.index("\nPY\n", opener)
    return text[opener:closer]


TRANSFORMS = {
    "builder": extract_transform(BUILDER, 'install -m 0600 "${source_files[0]}"'),
    "manager": extract_transform(MANAGER, "build_variant_dsdt()"),
}
BUILDER_ROUNDTRIP_VERIFIER = extract_transform(BUILDER, "verify_roundtrip_semantics()")
MANAGER_ROUNDTRIP_VERIFIER = extract_transform(
    MANAGER, 'python3 - "$aml" "$roundtrip_dsl"'
)


def run_transform(code: str, source_text: str, variant: str, revision: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="omen-transform-test.") as temporary:
        directory = Path(temporary)
        source = directory / "source.dsl"
        destination = directory / "output.dsl"
        source.write_text(source_text, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "-c", code, str(source), str(destination), variant, revision],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            result.output_text = destination.read_text(encoding="utf-8")  # type: ignore[attr-defined]
        return result


def run_builder_roundtrip_verifier(
    source_text: str, variant: str
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="omen-roundtrip-test.") as temporary:
        source = Path(temporary) / "DSDT.dsl"
        source.write_text(source_text, encoding="utf-8")
        return subprocess.run(
            [
                sys.executable,
                "-c",
                BUILDER_ROUNDTRIP_VERIFIER,
                str(source),
                variant,
            ],
            text=True,
            capture_output=True,
            check=False,
        )


def run_manager_roundtrip_verifier(
    source_text: str, variant: str
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="omen-manager-roundtrip-test.") as temporary:
        directory = Path(temporary)
        source = directory / "DSDT.dsl"
        aml = directory / "DSDT.aml"
        revision = 0x0107200A if variant == "s5" else 0x0107200B
        source.write_text(source_text, encoding="utf-8")

        data = bytearray(36)
        data[0:4] = b"DSDT"
        struct.pack_into("<I", data, 4, len(data))
        data[8] = 2
        data[10:16] = b"HPQOEM"
        data[16:24] = b"8E35    "
        struct.pack_into("<I", data, 24, revision)
        data[28:32] = b"INTL"
        struct.pack_into("<I", data, 32, 1)
        data[9] = (-sum(data)) & 0xFF
        aml.write_bytes(data)

        return subprocess.run(
            [
                sys.executable,
                "-c",
                MANAGER_ROUNDTRIP_VERIFIER,
                str(aml),
                str(source),
                variant,
                f"0x{revision:08X}",
            ],
            text=True,
            capture_output=True,
            check=False,
        )


ROUNDTRIP_VERIFIERS = {
    "builder": run_builder_roundtrip_verifier,
    "manager": run_manager_roundtrip_verifier,
}


def verify_output(output: str, variant: str, revision: str) -> None:
    assert f'"8E35    ", {revision})' in output
    ompr = output.index("Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)")
    ps3 = output.index("\\_SB.PCI0.GPP0.PEGP._PS3 ()")
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


def main() -> None:
    assert "iasl -dl -d DSDT.aml" in MANAGER.read_text(encoding="utf-8"), (
        "manager round trip must use the legacy ASL dialect"
    )
    transformed_outputs: dict[str, str] = {}
    for engine, code in TRANSFORMS.items():
        for variant, revision in (("s5", "0x0107200A"), ("combined", "0x0107200B")):
            result = run_transform(code, FIXTURE, variant, revision)
            if result.returncode != 0:
                raise AssertionError(f"{engine}/{variant} failed: {result.stderr}")
            output = result.output_text  # type: ignore[attr-defined]
            verify_output(output, variant, revision)
            if engine == "builder":
                transformed_outputs[variant] = output

        extra_loop = FIXTURE + "\n" + ORIGINAL_LOOP_BLOCK
        result = run_transform(code, extra_loop, "combined", "0x0107200B")
        assert result.returncode != 0, f"{engine} accepted a loop outside WQBZ"

        result = run_transform(code, extra_loop, "s5", "0x0107200A")
        assert result.returncode != 0, f"{engine} accepted an extra S5 loop outside WQBZ"

        missing_loop = FIXTURE.replace(ORIGINAL_LOOP_BLOCK, "", 1)
        result = run_transform(code, missing_loop, "s5", "0x0107200A")
        assert result.returncode != 0, f"{engine} accepted a missing S5 WQBZ loop"

    unrelated_s5_checks = r'''
    Method (TST5, 1, NotSerialized)
    {
        If (LEqual (Arg0, 0x05))
        {
            Noop
        }
        If (LEqual (Arg0, 0x05))
        {
            Noop
        }
        If (LEqual (Arg0, 0x05))
        {
            Noop
        }
    }
'''
    for variant, output in transformed_outputs.items():
        with_unrelated_checks = output.rsplit("}", 1)[0] + unrelated_s5_checks + "}\n"
        for verifier_name, verifier in ROUNDTRIP_VERIFIERS.items():
            result = verifier(with_unrelated_checks, variant)
            assert result.returncode == 0, (
                f"{verifier_name} round-trip verifier rejected unrelated "
                f"Arg0 == 5 checks/{variant}: {result.stderr}"
            )

        duplicate_pts_guard = output.replace(
            "If (LEqual (Arg0, 0x05))",
            "If (LEqual (Arg0, 0x05))\n            If (LEqual (Arg0, 0x05))",
            1,
        )
        for verifier_name, verifier in ROUNDTRIP_VERIFIERS.items():
            result = verifier(duplicate_pts_guard, variant)
            assert result.returncode != 0, (
                f"{verifier_name} round-trip verifier accepted duplicate "
                f"_PTS S5 guard/{variant}"
            )

        duplicate_critical_operation = output.rsplit("}", 1)[0] + (
            "\n    Method (BAD5, 0, NotSerialized)\n"
            "    {\n"
            "        Store (0x03, \\_SB.PCI0.GPP0.PEGP.OMPR)\n"
            "    }\n"
            "}\n"
        )
        for verifier_name, verifier in ROUNDTRIP_VERIFIERS.items():
            result = verifier(duplicate_critical_operation, variant)
            assert result.returncode != 0, (
                f"{verifier_name} round-trip verifier accepted a duplicate "
                f"critical operation/{variant}"
            )

        if variant == "s5":
            missing_original_loop = output.replace(ORIGINAL_LOOP_BLOCK, "", 1)
        else:
            missing_original_loop = output.replace(
                "While (LLess (Local5, SizeOf (BF01)))",
                "While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))",
                1,
            )
        for verifier_name, verifier in ROUNDTRIP_VERIFIERS.items():
            result = verifier(missing_original_loop, variant)
            assert result.returncode != 0, (
                f"{verifier_name} round-trip verifier accepted incorrect "
                f"WQBZ loop semantics/{variant}"
            )

    print("transform tests: PASS")


if __name__ == "__main__":
    main()
