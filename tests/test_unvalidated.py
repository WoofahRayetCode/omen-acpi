#!/usr/bin/env python3
"""Synthetic coverage for the unvalidated-machine opt-in boundary."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "omen-acpi"
REFERENCE = ("OMEN Gaming Laptop 16-ap0xxx", "8E35", "F.13")
QUESTION = "Proceed on this unvalidated machine? [y/N]"


def cli_script(body: str) -> str:
    return f'''source "$1"
machine_values() {{
    MACHINE_PRODUCT="$TEST_PRODUCT"
    MACHINE_BOARD="$TEST_BOARD"
    MACHINE_BIOS="$TEST_BIOS"
}}
{body}
'''


def cli_env(identity: tuple[str, str, str], home: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        OMEN_ACPI_SOURCE_ONLY="1",
        OMEN_ACPI_TESTING="1",
        HOME=str(home),
        TEST_PRODUCT=identity[0],
        TEST_BOARD=identity[1],
        TEST_BIOS=identity[2],
        TERM="dumb",
    )
    environment.pop("OMEN_ACPI_UNVALIDATED_OPT_IN", None)
    return environment


def run_cli_tty(identity: tuple[str, str, str], answer: bytes, body: str,
                home: Path) -> tuple[int, str]:
    pid, descriptor = pty.fork()
    if pid == 0:
        os.execve(
            "/usr/bin/bash",
            ["bash", "-c", cli_script(body), "_", str(FRONTEND)],
            cli_env(identity, home),
        )
    if answer:
        os.write(descriptor, answer)
    output = bytearray()
    status = None
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        ready, _, _ = select.select([descriptor], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(descriptor, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        waited, child_status = os.waitpid(pid, os.WNOHANG)
        if waited:
            status = child_status
            break
    if status is None:
        if time.monotonic() >= deadline:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            raise AssertionError("CLI opt-in test timed out")
        _, status = os.waitpid(pid, 0)
    os.close(descriptor)
    return os.waitstatus_to_exitcode(status), output.decode("utf-8", "replace")


def run_cli_plain(identity: tuple[str, str, str], body: str,
                  home: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", cli_script(body), "_", str(FRONTEND)],
        text=True,
        capture_output=True,
        env=cli_env(identity, home),
        check=False,
    )


def extract_bash_function(path: Path, name: str) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    start = lines.index(f"{name}() {{")
    heredoc = False
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if heredoc:
            if line == "PY":
                heredoc = False
            continue
        if "<<'PY'" in line:
            heredoc = True
        elif line == "}":
            return "\n".join(lines[start:index + 1]) + "\n"
    raise AssertionError(f"unterminated Bash function: {path}:{name}")


def engine_check(path: Path, functions: tuple[str, ...], identity: tuple[str, str, str],
                 indicator: bool) -> subprocess.CompletedProcess[str]:
    extracted = "\n".join(extract_bash_function(path, name) for name in functions)
    script = f'''
EXPECTED_PRODUCT={shlex.quote(REFERENCE[0])}
EXPECTED_BOARD={shlex.quote(REFERENCE[1])}
EXPECTED_BIOS={shlex.quote(REFERENCE[2])}
MACHINE_PRODUCT=
MACHINE_BOARD=
MACHINE_BIOS=
PACKAGE_FORMAT=
die() {{ printf 'ERROR: %s\\n' "$*" >&2; exit 1; }}
cat() {{
    case "$1" in
        */product_name) printf '%s\\n' "$TEST_PRODUCT" ;;
        */board_name) printf '%s\\n' "$TEST_BOARD" ;;
        */bios_version) printf '%s\\n' "$TEST_BIOS" ;;
        *) command cat "$@" ;;
    esac
}}
{extracted}
check_machine
printf 'FORMAT=%s\\n' "$PACKAGE_FORMAT"
'''
    environment = os.environ.copy()
    environment.update(TEST_PRODUCT=identity[0], TEST_BOARD=identity[1], TEST_BIOS=identity[2])
    if indicator:
        environment["OMEN_ACPI_UNVALIDATED_OPT_IN"] = "1"
    else:
        environment.pop("OMEN_ACPI_UNVALIDATED_OPT_IN", None)
    return subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                          env=environment, check=False)


def load_module(path: Path, name: str):
    specification = importlib.util.spec_from_file_location(name, path)
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def source_metadata(identity: tuple[str, str, str], package_format: str = "3") -> str:
    return "\n".join((
        f"PACKAGE_FORMAT={package_format}",
        f"DMI_PRODUCT={identity[0]}",
        f"MAINBOARD={identity[1]}",
        f"BIOS={identity[2]}",
        "ORIGINAL_DSDT_OEM_REVISION=0x01072009",
        f"ORIGINAL_DSDT_SHA256={'a' * 64}",
        "",
    ))


def build_metadata(identity: tuple[str, str, str]) -> str:
    return "\n".join((
        "PACKAGE_FORMAT=3",
        "VARIANT=s5",
        "PATCH=S5_ONLY",
        "WQBZ_WORKAROUND=NO",
        f"DMI_PRODUCT={identity[0]}",
        f"MAINBOARD={identity[1]}",
        f"BIOS={identity[2]}",
        "ORIGINAL_DSDT_OEM_REVISION=0x01072009",
        f"ORIGINAL_DSDT_SHA256={'a' * 64}",
        "PATCHED_DSDT_OEM_REVISION=0x0107200A",
        "BUILD_KERNEL=test",
        "",
    ))


def test_cli() -> None:
    body = 'require_transform_machine\nrequire_transform_machine\nprintf "CONSENT=%s\\n" "$UNVALIDATED_CONSENT"'
    with tempfile.TemporaryDirectory(prefix="omen-opt-in-cli.") as temporary:
        home = Path(temporary)
        reference = run_cli_plain(REFERENCE, body, home)
        assert reference.returncode == 0 and QUESTION not in reference.stdout + reference.stderr

        changed = (
            ("Other product", REFERENCE[1], REFERENCE[2]),
            (REFERENCE[0], "Other board", REFERENCE[2]),
            (REFERENCE[0], REFERENCE[1], "Other BIOS"),
        )
        for identity in changed:
            status, output = run_cli_tty(identity, b"y\n", body, home)
            assert status == 0 and "CONSENT=1" in output and output.count(QUESTION) == 1
            assert "UNVALIDATED / OPT-IN REQUIRED" in output

        for answer in (b"n\n", b"\n", b"anything\n"):
            status, output = run_cli_tty(changed[0], answer, body, home)
            assert status != 0 and output.count(QUESTION) == 1

        status, output = run_cli_tty(changed[0], b"yes\n", body, home)
        assert status == 0 and "CONSENT=1" in output
        for answer in (b"Y\n", b"YES\n"):
            status, output = run_cli_tty(changed[0], answer, body, home)
            assert status == 0 and "CONSENT=1" in output

        for identity in (("", REFERENCE[1], REFERENCE[2]),
                         (REFERENCE[0], "", REFERENCE[2]),
                         (REFERENCE[0], REFERENCE[1], "")):
            status, output = run_cli_tty(identity, b"yes\n", body, home)
            assert status != 0 and QUESTION not in output and "missing, empty or unreadable" in output

        noninteractive = run_cli_plain(changed[0], body, home)
        assert noninteractive.returncode != 0
        assert "interactive terminal" in noninteractive.stderr

        yes_body = '''
ensure_dependencies() { : > "$TEST_MARKER"; }
ensure_user_directories() { : > "$TEST_MARKER"; }
require_stock_boot() { : > "$TEST_MARKER"; }
main --yes collect
'''
        marker = home / "pre-consent-write"
        environment_body = yes_body.replace("$TEST_MARKER", str(marker))
        status, output = run_cli_tty(changed[0], b"\n", environment_body, home)
        assert status != 0 and QUESTION in output and not marker.exists()

        first = run_cli_tty(changed[0], b"yes\n", body, home)[1]
        second = run_cli_tty(changed[0], b"yes\n", body, home)[1]
        assert first.count(QUESTION) == second.count(QUESTION) == 1

        read_only = '''
ensure_dependencies() { :; }
probe_boot() { PROBE_STATE=stock; PROBE_CLEAN=1; PROBE_REVISION=x; PROBE_REASON=test; }
refine_installation_formats_cached() { :; }
stock_recovery_status() { printf 'SNAPSHOT\\tmissing\\n'; }
status_one() { printf 'STATUS_OK\\n'; }
remove_one() { printf 'REMOVE_OK\\n'; }
print_missing_dependencies() { return 0; }
collect_missing_dependencies() { MISSING_PACKAGES=(fixture); }
secure_boot_state() { printf 'unknown\\n'; }
status_variants all
remove_variants all
doctor
'''
        result = run_cli_plain(changed[0], read_only, home)
        assert result.returncode == 0 and "STATUS_OK" in result.stdout and "REMOVE_OK" in result.stdout
        assert "UNVALIDATED / OPT-IN REQUIRED" in result.stderr
        assert QUESTION not in result.stdout + result.stderr

        reboot = '''
ensure_dependencies() { :; }
probe_boot() { PROBE_STATE=s5; PROBE_CLEAN=0; PROBE_REVISION=x; PROBE_REASON=test; }
get_stock_entry() { printf 'Linux-CachyOS\\n'; }
confirm_dangerous() { return 1; }
main reboot-stock
'''
        result = run_cli_plain(changed[0], reboot, home)
        assert result.returncode == 0 and "Linux-CachyOS" in result.stdout
        assert QUESTION not in result.stdout + result.stderr

        recover = '''
ensure_dependencies() { :; }
ensure_admin() { :; }
probe_boot() { PROBE_STATE=s5; PROBE_CLEAN=0; PROBE_REVISION=x; PROBE_REASON=test; }
stock_recovery_manager() {
    case "$1" in
        status) printf 'SNAPSHOT\\tmissing\\nNORMAL_ENTRY\\tavailable\\n' ;;
        recover) printf 'NORMAL\\tLinux-CachyOS\\n' ;;
    esac
}
show_stock_reboot_prompt() { printf 'RECOVERY_NORMAL_OK\\n'; }
main recover-stock
'''
        result = run_cli_plain(changed[0], recover, home)
        assert result.returncode == 0 and "RECOVERY_NORMAL_OK" in result.stdout
        assert QUESTION not in result.stdout + result.stderr


def test_engines() -> None:
    engines = (
        (ROOT / "scripts/01-collect-acpi.sh", ("check_machine",)),
        (ROOT / "scripts/02-build-dsdt.sh", ("check_machine",)),
        (ROOT / "scripts/03-manage-limine-entry.sh",
         ("read_machine", "machine_is_reference", "check_machine")),
    )
    unvalidated = ("Other product", "Other board", "Other BIOS")
    for path, functions in engines:
        assert engine_check(path, functions, REFERENCE, False).stdout.strip() == "FORMAT=2"
        rejected = engine_check(path, functions, unvalidated, False)
        assert rejected.returncode != 0 and "internal CLI opt-in indicator" in rejected.stderr
        accepted = engine_check(path, functions, unvalidated, True)
        assert accepted.returncode == 0 and accepted.stdout.strip() == "FORMAT=3"
        unreadable = engine_check(path, functions, ("", "board", "bios"), True)
        assert unreadable.returncode != 0 and "missing, empty or unreadable" in unreadable.stderr

    recovery = load_module(ROOT / "scripts/04-stock-recovery.py", "opt_in_recovery")
    with tempfile.TemporaryDirectory(prefix="omen-opt-in-recovery.") as temporary:
        test_root = Path(temporary)
        dmi = test_root / "sys/class/dmi/id"
        dmi.mkdir(parents=True)
        for name, value in zip(("product_name", "board_name", "bios_version"), unvalidated):
            (dmi / name).write_text(value + "\n", encoding="utf-8")
        old_root = os.environ.get("OMEN_ACPI_TEST_ROOT")
        old_indicator = os.environ.pop("OMEN_ACPI_UNVALIDATED_OPT_IN", None)
        os.environ["OMEN_ACPI_TEST_ROOT"] = str(test_root)
        try:
            try:
                recovery.require_transform_machine()
            except recovery.Failure:
                pass
            else:
                raise AssertionError("Python engine accepted unvalidated DMI without indicator")
            os.environ["OMEN_ACPI_UNVALIDATED_OPT_IN"] = "1"
            assert recovery.require_transform_machine() == unvalidated
            (dmi / "bios_version").write_text("\n", encoding="utf-8")
            try:
                recovery.require_transform_machine()
            except recovery.Failure:
                pass
            else:
                raise AssertionError("Python engine accepted empty DMI with indicator")
        finally:
            if old_root is None:
                os.environ.pop("OMEN_ACPI_TEST_ROOT", None)
            else:
                os.environ["OMEN_ACPI_TEST_ROOT"] = old_root
            if old_indicator is None:
                os.environ.pop("OMEN_ACPI_UNVALIDATED_OPT_IN", None)
            else:
                os.environ["OMEN_ACPI_UNVALIDATED_OPT_IN"] = old_indicator


def test_artifact_identity_and_structure() -> None:
    identity = ("Opted product", "Opted board", "BIOS A")
    changed_bios = (identity[0], identity[1], "BIOS B")
    with tempfile.TemporaryDirectory(prefix="omen-opt-in-artifact.") as temporary:
        work = Path(temporary)
        source_info = work / "SOURCE.txt"
        source_info.write_text(source_metadata(identity), encoding="utf-8")
        reader = extract_bash_function(ROOT / "scripts/02-build-dsdt.sh", "read_source_fingerprint")

        def run_reader(current: tuple[str, str, str]) -> subprocess.CompletedProcess[str]:
            script = f'''MACHINE_PRODUCT={shlex.quote(current[0])}
MACHINE_BOARD={shlex.quote(current[1])}
MACHINE_BIOS={shlex.quote(current[2])}
{reader}
read_source_fingerprint "$1"
'''
            return subprocess.run(["bash", "-c", script, "_", str(source_info)], text=True,
                                  capture_output=True, check=False)

        assert run_reader(identity).returncode == 0
        assert run_reader(("Another machine", identity[1], identity[2])).returncode != 0
        assert run_reader(changed_bios).returncode != 0

        archive = work / "build.tar.gz"
        package = work / "package"
        package.mkdir()
        (package / "DSDT-original.dsl").write_text("stock source\n", encoding="utf-8")
        (package / "BUILD-INFO.txt").write_text(build_metadata(identity), encoding="utf-8")
        with tarfile.open(archive, "w:gz") as output:
            output.add(package, arcname="build")
        copier = extract_bash_function(ROOT / "scripts/03-manage-limine-entry.sh",
                                       "safe_copy_source_dsl")

        def run_copier(current: tuple[str, str, str], suffix: str) -> subprocess.CompletedProcess[str]:
            destination = work / suffix / "DSDT-original.dsl"
            fingerprint = work / suffix / "original.sha256"
            script = f'''VARIANT=s5
EXPECTED_PATCHED_REVISION=0x0107200A
MACHINE_PRODUCT={shlex.quote(current[0])}
MACHINE_BOARD={shlex.quote(current[1])}
MACHINE_BIOS={shlex.quote(current[2])}
{copier}
safe_copy_source_dsl "$1" "$2" "$3"
'''
            return subprocess.run(
                ["bash", "-c", script, "_", str(archive), str(destination), str(fingerprint)],
                text=True, capture_output=True, check=False,
            )

        assert run_copier(identity, "matching").returncode == 0
        assert run_copier(("Another machine", identity[1], identity[2]), "foreign").returncode != 0
        assert run_copier(changed_bios, "changed-bios").returncode != 0

    transforms = load_module(ROOT / "tests/test_transform.py", "opt_in_transforms")
    incompatible = transforms.FIXTURE.replace("Method (_PTS, 1, NotSerialized)",
                                              "Method (_PTS, 2, NotSerialized)")
    for engine, code in transforms.TRANSFORMS.items():
        result = transforms.run_transform(code, incompatible, "s5", "0x0107200A")
        assert result.returncode != 0, f"{engine} accepted structurally incompatible opted-in DSDT"


def main() -> None:
    test_cli()
    test_engines()
    test_artifact_identity_and_structure()
    print("unvalidated opt-in tests: PASS")


if __name__ == "__main__":
    main()
