#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

readonly ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d /tmp/omen-acpi-tests.XXXXXX)"

cleanup() {
    case "${work:-}" in
        /tmp/omen-acpi-tests.*) rm -rf -- "$work" ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'TEST FAILURE: %s\n' "$*" >&2
    exit 1
}

printf 'syntax checks...\n'
for script in \
    "$ROOT/omen-acpi" \
    "$ROOT/install.sh" \
    "$ROOT/uninstall.sh" \
    "$ROOT"/scripts/*.sh \
    "$ROOT/tests/run.sh"; do
    bash -n "$script" || fail "bash syntax: $script"
done

printf 'release manifest checks...\n'
python3 - "$ROOT" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

root = Path(sys.argv[1])
installer_lines = (root / "install.sh").read_text(encoding="utf-8").splitlines()
try:
    start = installer_lines.index("release_files=(") + 1
    end = installer_lines.index(")", start)
except ValueError as error:
    raise SystemExit("could not parse install.sh release_files array") from error

release_files = []
for raw in installer_lines[start:end]:
    name = raw.strip()
    if not name or re.fullmatch(r"[A-Za-z0-9._/-]+", name) is None:
        raise SystemExit(f"invalid release_files entry in install.sh: {raw!r}")
    release_files.append(name)
if len(release_files) != len(set(release_files)):
    raise SystemExit("install.sh release_files contains duplicates")

manifest_path = root / "SHA256SUMS"
if not manifest_path.is_file() or manifest_path.is_symlink():
    raise SystemExit("SHA256SUMS is missing or unsafe")
manifest = {}
for line_number, line in enumerate(
    manifest_path.read_text(encoding="ascii").splitlines(), 1
):
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
    if match is None:
        raise SystemExit(f"malformed SHA256SUMS line {line_number}")
    digest, name = match.groups()
    if name in manifest:
        raise SystemExit(f"duplicate SHA256SUMS path: {name}")
    manifest[name] = digest

if set(manifest) != set(release_files):
    missing = sorted(set(release_files) - set(manifest))
    extra = sorted(set(manifest) - set(release_files))
    raise SystemExit(f"release manifest coverage mismatch: missing={missing}, extra={extra}")

for name in release_files:
    path = root / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"release file is missing or unsafe: {name}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != manifest[name]:
        raise SystemExit(f"release checksum mismatch: {name}")

for path in root.rglob("*"):
    if ".git" in path.parts:
        continue
    if path.is_symlink():
        raise SystemExit(f"unexpected symlink in release tree: {path.relative_to(root)}")
    if path.name == "__pycache__" or path.suffix in {".pyc", ".pyo"}:
        raise SystemExit(f"Python cache in release tree: {path.relative_to(root)}")

print(f"release files verified: {len(release_files)}")
PY

printf 'version consistency checks...\n'
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
expected = "2.1.11"
for relative in ("install.sh", "omen-acpi", "scripts/03-manage-limine-entry.sh"):
    values = re.findall(r'^readonly VERSION="([0-9.]+)"$', (root / relative).read_text(), re.MULTILINE)
    if values != [expected]:
        raise SystemExit(f"version mismatch in {relative}: {values}")
values = re.findall(r'^VERSION = "([0-9.]+)"$', (root / "scripts/04-stock-recovery.py").read_text(), re.MULTILINE)
if values != [expected]:
    raise SystemExit(f"version mismatch in Python recovery manager: {values}")
for verifier in ("tools/make-release.sh", "update.sh"):
    source = (root / verifier).read_text()
    if "scripts/04-stock-recovery.py" not in source:
        raise SystemExit(f"{verifier} omits the Python recovery-manager version")
print("component versions agree and both release verifiers cover Python")
PY

printf 'embedded Python checks...\n'
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
count = 0
for path in [root / "omen-acpi", *sorted((root / "scripts").glob("*.sh"))]:
    lines = path.read_text(encoding="utf-8").splitlines()
    index = 0
    while index < len(lines):
        if "<<'PY'" not in lines[index]:
            index += 1
            continue
        start = index + 1
        end = start
        while end < len(lines) and lines[end] != "PY":
            end += 1
        if end == len(lines):
            raise SystemExit(f"unterminated Python heredoc in {path}:{index + 1}")
        compile("\n".join(lines[start:end]) + "\n", f"{path}:{start + 1}", "exec")
        count += 1
        index = end + 1
print(f"embedded Python blocks compiled: {count}")
PY

printf 'CLI smoke checks...\n'
cli_help="$(OMEN_ACPI_TESTING=1 HOME="$work/home" "$ROOT/omen-acpi" --plain --help)"
grep -Fq 'omen-acpi setup [s5|combined|both]' <<<"$cli_help" \
    || fail "CLI help"
for recovery_command in prepare-stock-recovery recover-stock reboot-stock remove-stock-recovery; do
    grep -Fq "omen-acpi $recovery_command" <<<"$cli_help" \
        || fail "CLI help omits $recovery_command"
done
grep -Fq '2.1.9' "$ROOT/README.md" \
    || fail "2.1.9 upgrade limitation is not documented"
grep -Fq 'external manual recovery' "$ROOT/README.md" \
    || fail "missing-snapshot manual recovery limitation is not documented"
for removed_command in migrate restore-legacy refresh; do
    if grep -Eq "^[[:space:]]*omen-acpi ${removed_command}([[:space:]]|$)" <<<"$cli_help"; then
        fail "removed command is still advertised: $removed_command"
    fi
done
[[ "$(OMEN_ACPI_TESTING=1 HOME="$work/home" "$ROOT/omen-acpi" --plain version)" \
    == 'OMEN ACPI Toolkit 2.1.11' ]] || fail "CLI version"
[[ "$(OMEN_ACPI_TESTING=1 HOME="$work/home" "$ROOT/omen-acpi" version --plain)" \
    == 'OMEN ACPI Toolkit 2.1.11' ]] || fail "global option after command"

for invalid_case in \
    'setup invalid' \
    'doctor --invalid' \
    'dependencies --invalid' \
    'status both' \
    'remove both'; do
    read -r -a invalid_arguments <<<"$invalid_case"
    if OMEN_ACPI_TESTING=1 HOME="$work/home" \
        "$ROOT/omen-acpi" "${invalid_arguments[@]}" \
        >"$work/invalid.out" 2>"$work/invalid.err"; then
        fail "CLI accepted invalid arguments: $invalid_case"
    fi
    grep -Fq 'Usage: omen-acpi' "$work/invalid.err" \
        || fail "invalid CLI arguments did not fail with usage: $invalid_case"
done

for removed_command in migrate restore-legacy refresh; do
    if OMEN_ACPI_TESTING=1 HOME="$work/home" \
        "$ROOT/omen-acpi" "$removed_command" s5 \
        >"$work/removed.out" 2>"$work/removed.err"; then
        fail "CLI accepted removed command: $removed_command"
    fi
    grep -Fq 'This command was removed.' "$work/removed.err" \
        || fail "removed CLI command did not explain the replacement flow: $removed_command"
done

for removed_action in migrate restore-legacy refresh; do
    if "$ROOT/scripts/03-manage-limine-entry.sh" "$removed_action" s5 \
        >"$work/removed-manager.out" 2>"$work/removed-manager.err"; then
        fail "private manager accepted removed action: $removed_action"
    fi
    grep -Fq 'state-conversion action was removed' "$work/removed-manager.err" \
        || fail "removed private-manager action did not fail closed: $removed_action"
done

fake_sudo="$work/fake-sudo"
cat > "$fake_sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OMEN_ACPI_TEST_SUDO_LOG"
exit 0
EOF
chmod 0700 "$fake_sudo"
sed "s|readonly SUDO_BIN=\"/usr/bin/sudo\"|readonly SUDO_BIN=\"$fake_sudo\"|" \
    "$ROOT/omen-acpi" > "$work/omen-acpi"
chmod 0700 "$work/omen-acpi"
ln -s "$ROOT/scripts" "$work/scripts"
ln -s "$ROOT/uninstall.sh" "$work/uninstall.sh"

OMEN_ACPI_TEST_SUDO_LOG="$work/sudo.log" \
python3 - "$work/omen-acpi" "$work/home" <<'PY'
import errno
import os
from pathlib import Path
import pty
import select
import signal
import sys
import time

frontend = Path(sys.argv[1])
home = Path(sys.argv[2])


def run_tty(*arguments: str, keys: bytes = b"q\n") -> bytes:
    environment = os.environ.copy()
    environment.pop("NO_COLOR", None)
    environment.update(
        HOME=str(home),
        LANG="C.UTF-8",
        OMEN_ACPI_TESTING="1",
        TERM="xterm-256color",
    )
    pid, descriptor = pty.fork()
    if pid == 0:
        os.execve(
            frontend,
            [str(frontend), *arguments],
            environment,
        )

    output = bytearray()
    exit_status = None
    os.write(descriptor, keys)
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([descriptor], [], [], 0.25)
            if not ready:
                waited, status = os.waitpid(pid, os.WNOHANG)
                if waited:
                    exit_status = status
                    break
                continue
            try:
                chunk = os.read(descriptor, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
        else:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            raise SystemExit("interactive CLI smoke test timed out")

        if exit_status is None:
            waited, status = os.waitpid(pid, os.WNOHANG)
            if not waited:
                _, status = os.waitpid(pid, 0)
            exit_status = status
        if os.waitstatus_to_exitcode(exit_status) != 0:
            raise SystemExit("interactive CLI returned a failure")
    finally:
        os.close(descriptor)
    return bytes(output)


plain = run_tty("--plain")
if b"\x1b" in plain:
    raise SystemExit("--plain emitted an ANSI escape sequence")
plain.decode("ascii", "strict")
if b"omen-acpi > " not in plain:
    raise SystemExit("--plain did not use the ASCII prompt")

styled = run_tty()
styled_text = styled.decode("utf-8", "strict")
if b"\x1b" not in styled or "OMEN ACPI Toolkit" not in styled_text:
    raise SystemExit("styled TTY dashboard did not render")

# A menu action that fails must return to the menu. Every action calls die(),
# which exits the process, so each one has to be contained in a subshell.
menu_text = run_tty("--plain", keys=b"5\n5\n\nb\nq\n").decode("utf-8", "replace")
if "No operation log has been recorded yet." not in menu_text:
    raise SystemExit("advanced menu did not report the missing operation log")
if menu_text.count("What would you like to do?") < 2:
    raise SystemExit("a failing menu action terminated the interactive CLI")

print("TTY and plain-mode checks: PASS")
PY
[[ ! -e "$work/sudo.log" ]] \
    || fail "interactive test reached sudo: $(tr '\n' ';' < "$work/sudo.log")"

printf 'frontend state checks...\n'
mkdir -p "$work/frontend"
ln -s "$ROOT/scripts" "$work/frontend/scripts"
cp "$ROOT/omen-acpi" "$work/frontend/omen-acpi"
(
    export OMEN_ACPI_TESTING=1
    export OMEN_ACPI_SOURCE_ONLY=1
    export HOME="$work/frontend-home"
    export XDG_DATA_HOME="$HOME/data"
    export XDG_STATE_HOME="$HOME/state"
    # shellcheck disable=SC1090
    source "$work/frontend/omen-acpi"

    stock_hash="$(printf 'a%.0s' {1..64})"
    stock_probe="$(cat <<EOF
STATE=stock
CLEAN=1
REASON=original-revision-no-acpi-taint
DSDT_REVISION=0x01072009
DSDT_SHA256=$stock_hash
TAINT_ACPI=0
LOG_OVERRIDE=0
EOF
)"

    parse_probe_output "$stock_probe"
    [[ "$PROBE_STATE:$PROBE_CLEAN" == "stock:1" ]] \
        || fail "first-run stock classification"

    legacy_probe="$(cat <<EOF
STATE=combined
CLEAN=0
REASON=legacy-combined-hash
DSDT_REVISION=0x0107200B
DSDT_SHA256=$(printf 'c%.0s' {1..64})
TAINT_ACPI=0
LOG_OVERRIDE=1
S5_FORMAT=legacy
COMBINED_FORMAT=legacy
ACTIVE_FORMAT=legacy
EOF
)"
    parse_probe_output "$legacy_probe"
    [[ "$(boot_state_label)" == "LEGACY COMBINED ACTIVE" ]] \
        || fail "legacy active boot label"
    [[ "$(variant_dashboard_status s5)" == "LEGACY / REINSTALL" ]] \
        || fail "legacy dashboard status"

    parse_probe_output "$stock_probe"

    mkdir -p "$(dirname "$STOCK_FINGERPRINT")"
    printf '%s\n' "$stock_hash" > "$STOCK_FINGERPRINT"
    parse_probe_output "$stock_probe"
    [[ "$PROBE_STATE:$PROBE_CLEAN" == "stock:1" ]] \
        || fail "matching saved stock fingerprint"

    printf 'malformed\n' > "$STOCK_FINGERPRINT"
    parse_probe_output "$stock_probe"
    [[ "$PROBE_STATE:$PROBE_CLEAN:$PROBE_REASON" == \
        "unknown:0:stock-fingerprint-invalid" ]] \
        || fail "malformed stock fingerprint did not fail closed"

    rm -f -- "$STOCK_FINGERPRINT"
    ln -s /dev/null "$STOCK_FINGERPRINT"
    parse_probe_output "$stock_probe"
    [[ "$PROBE_STATE:$PROBE_CLEAN:$PROBE_REASON" == \
        "unknown:0:stock-fingerprint-invalid" ]] \
        || fail "symlink stock fingerprint did not fail closed"

    rm -f -- "$STOCK_FINGERPRINT"
    printf 'b%.0s' {1..64} > "$STOCK_FINGERPRINT"
    printf '\n' >> "$STOCK_FINGERPRINT"
    parse_probe_output "$stock_probe"
    [[ "$PROBE_STATE:$PROBE_CLEAN:$PROBE_REASON" == \
        "unknown:0:stock-fingerprint-mismatch" ]] \
        || fail "mismatched stock fingerprint did not fail closed"

    clear_pending_action
    set_pending_action install combined
    [[ "$(pending_description)" == "install combined" ]] \
        || fail "pending install variant was not preserved"
    pending_is_same_boot || fail "new pending action has the wrong boot ID"
    clear_pending_action

    set_pending_action setup both
    [[ "$(pending_description)" == "setup both" ]] \
        || fail "pending setup selection was not preserved"
    pending_is_same_boot || fail "pending setup has the wrong boot ID"
    clear_pending_action
)

fixture="$work/root"
mkdir -p \
    "$fixture/sys/class/dmi/id" \
    "$fixture/sys/firmware/acpi/tables" \
    "$fixture/proc/sys/kernel" \
    "$fixture/proc"
printf '%s\n' 'OMEN Gaming Laptop 16-ap0xxx' > "$fixture/sys/class/dmi/id/product_name"
printf '%s\n' '8E35' > "$fixture/sys/class/dmi/id/board_name"
printf '%s\n' 'F.13' > "$fixture/sys/class/dmi/id/bios_version"
printf '0\n' > "$fixture/proc/sys/kernel/tainted"
printf 'quiet splash\n' > "$fixture/proc/cmdline"
: > "$work/dmesg.log"

make_dsdt() {
    local revision="$1"
    python3 - "$fixture/sys/firmware/acpi/tables/DSDT" "$revision" <<'PY'
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
revision = int(sys.argv[2], 0)
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
path.write_bytes(data)
PY
}

probe_value() {
    local key="$1"
    OMEN_ACPI_TESTING=1 \
    OMEN_ACPI_TEST_ROOT="$fixture" \
    OMEN_ACPI_TEST_DMESG_FILE="$work/dmesg.log" \
        "$ROOT/scripts/00-probe-boot.sh" --env \
        | awk -F= -v key="$key" '$1 == key { print $2 }'
}

probe_state() {
    probe_value STATE
}

expect_state() {
    local expected="$1" actual
    actual="$(probe_state)"
    [[ "$actual" == "$expected" ]] \
        || fail "probe expected '$expected', got '$actual'"
}

expect_probe_value() {
    local key="$1" expected="$2" actual
    actual="$(probe_value "$key")"
    [[ "$actual" == "$expected" ]] \
        || fail "probe $key expected '$expected', got '$actual'"
}

reset_probe_fixture() {
    rm -rf -- \
        "$fixture/var/lib/omen-acpi-s5-test" \
        "$fixture/var/lib/omen-acpi-combined-test"
    printf '0\n' > "$fixture/proc/sys/kernel/tainted"
    printf 'quiet splash\n' > "$fixture/proc/cmdline"
}

make_managed_state() {
    local variant="$1" revision="$2" state_dir hash
    case "$variant" in
        s5) state_dir="$fixture/var/lib/omen-acpi-s5-test" ;;
        combined) state_dir="$fixture/var/lib/omen-acpi-combined-test" ;;
        *) fail "invalid managed-state fixture variant: $variant" ;;
    esac
    mkdir -p "$state_dir"
    cp -- "$fixture/sys/firmware/acpi/tables/DSDT" "$state_dir/DSDT.aml"
    hash="$(sha256sum -- "$state_dir/DSDT.aml" | awk '{print $1}')"
    printf '%s\n' "$hash" > "$state_dir/DSDT.sha256"
    printf '%s\n' "$variant" > "$state_dir/variant.txt"
    printf '%s\n' "$revision" > "$state_dir/expected-revision.txt"
}

write_legacy_manifest() {
    local variant="$1" state_dir="$2" state_aml aml_name initramfs_name legacy_root aml_hash
    case "$variant" in
        s5)
            state_aml="DSDT-S5-test.aml"
            aml_name="DSDT-OMEN-F13-S5-test.aml"
            initramfs_name="initramfs-omen-acpi-s5-test.img"
            legacy_root="/var/tmp/omen-s5-test.A1b2C3"
            ;;
        combined)
            state_aml="DSDT-combined-test.aml"
            aml_name="DSDT-OMEN-F13-combined-test.aml"
            initramfs_name="initramfs-omen-acpi-combined-test.img"
            legacy_root="/var/tmp/omen-combined-test.D4e5F6"
            ;;
        *) fail "invalid legacy-state fixture variant: $variant" ;;
    esac
    aml_hash="$(sha256sum -- "$state_dir/$state_aml" | awk '{print $1}')"
    {
        printf '%064d  /home/test/omen-dsdt-f13-build-fixture.tar.gz\n' 0
        printf '%s  %s/build/%s\n' "$aml_hash" "$legacy_root" "$aml_name"
        printf '%064d  %s/%s\n' 1 "$legacy_root" "$initramfs_name"
    } > "$state_dir/SHA256SUMS"
}

make_legacy_state() {
    local variant="$1" state_dir state_aml source_dsl
    case "$variant" in
        s5)
            state_dir="$fixture/var/lib/omen-acpi-s5-test"
            state_aml="DSDT-S5-test.aml"
            source_dsl="DSDT-OMEN-F13-S5-test.dsl"
            ;;
        combined)
            state_dir="$fixture/var/lib/omen-acpi-combined-test"
            state_aml="DSDT-combined-test.aml"
            source_dsl="DSDT-OMEN-F13-combined-test.dsl"
            ;;
        *) fail "invalid legacy-state fixture variant: $variant" ;;
    esac
    mkdir -p "$state_dir"
    cp -- "$fixture/sys/firmware/acpi/tables/DSDT" "$state_dir/$state_aml"
    : > "$state_dir/$source_dsl"
    : > "$state_dir/compile.log"
    : > "$state_dir/limine.conf.before"
    printf '%s\n' '/home/test/omen-dsdt-f13-build-fixture.tar.gz' \
        > "$state_dir/source-archive.txt"
    printf '%s\n' 'fixture-kernel' > "$state_dir/kernel-version.txt"
    printf '%s\n' 'Linux-CachyOS' > "$state_dir/source-entry.txt"
    write_legacy_manifest "$variant" "$state_dir"
}

printf 'boot-state classifier checks...\n'
reset_probe_fixture
make_dsdt 0x01072009
printf '%s\n' 'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' > "$work/dmesg.log"
expect_state stock
expect_probe_value LOG_EARLY_ACPI 1
expect_probe_value LOG_OVERRIDE 0

reset_probe_fixture
make_dsdt 0x0107200A
make_managed_state s5 0x0107200A
printf 'quiet omen_acpi.variant=s5\n' > "$fixture/proc/cmdline"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: Table Upgrade: override [DSDT-HPQOEM-8E35    ]' \
    > "$work/dmesg.log"
expect_state s5
expect_probe_value LOG_DSDT_OVERRIDE 1
expect_probe_value LOG_OTHER_ACPI 0
expect_probe_value S5_FORMAT managed
expect_probe_value ACTIVE_FORMAT managed
printf 'quiet splash\n' > "$fixture/proc/cmdline"
expect_state s5
expect_probe_value BOOT_MARKER none

reset_probe_fixture
make_dsdt 0x0107200B
make_managed_state combined 0x0107200B
printf 'quiet omen_acpi.variant=combined\n' > "$fixture/proc/cmdline"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: DSDT 0x0000000000000000 Physical table override, new table: 0x0000000000000000' \
    > "$work/dmesg.log"
expect_state combined
expect_probe_value COMBINED_FORMAT managed
expect_probe_value ACTIVE_FORMAT managed

reset_probe_fixture
make_dsdt 0x0107200A
make_legacy_state s5
printf 'quiet splash\n' > "$fixture/proc/cmdline"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: Table Upgrade: override [DSDT-HPQOEM-8E35    ]' \
    > "$work/dmesg.log"
expect_state s5
expect_probe_value REASON legacy-s5-hash
expect_probe_value S5_FORMAT legacy
expect_probe_value COMBINED_FORMAT absent
expect_probe_value ACTIVE_FORMAT legacy
printf 'quiet omen_acpi.variant=s5\n' > "$fixture/proc/cmdline"
expect_state unknown
expect_probe_value REASON acpi-state-disagreement

reset_probe_fixture
make_dsdt 0x0107200B
make_legacy_state combined
printf 'quiet splash\n' > "$fixture/proc/cmdline"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: DSDT 0x0000000000000000 Physical table override, new table: 0x0000000000000000' \
    > "$work/dmesg.log"
expect_state combined
expect_probe_value REASON legacy-combined-hash
expect_probe_value S5_FORMAT absent
expect_probe_value COMBINED_FORMAT legacy
expect_probe_value ACTIVE_FORMAT legacy

reset_probe_fixture
make_dsdt 0x0107200A
make_legacy_state s5
printf '%s\n' 'unexpected' > "$fixture/var/lib/omen-acpi-s5-test/extra.file"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: Table Upgrade: override [DSDT-HPQOEM-8E35    ]' \
    > "$work/dmesg.log"
expect_state unknown
expect_probe_value S5_FORMAT conflict
expect_probe_value ACTIVE_FORMAT none

reset_probe_fixture
make_dsdt 0x0107200A
make_legacy_state s5
rm -f -- "$fixture/var/lib/omen-acpi-s5-test/source-entry.txt"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: Table Upgrade: override [DSDT-HPQOEM-8E35    ]' \
    > "$work/dmesg.log"
expect_state unknown
expect_probe_value S5_FORMAT conflict
expect_probe_value ACTIVE_FORMAT none

reset_probe_fixture
make_dsdt 0x0107200B
make_legacy_state combined
python3 - "$fixture/var/lib/omen-acpi-combined-test/DSDT-combined-test.aml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[-1] ^= 1
path.write_bytes(data)
PY
write_legacy_manifest combined "$fixture/var/lib/omen-acpi-combined-test"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: DSDT 0x0000000000000000 Physical table override, new table: 0x0000000000000000' \
    > "$work/dmesg.log"
expect_state unknown
expect_probe_value COMBINED_FORMAT conflict
expect_probe_value ACTIVE_FORMAT none

reset_probe_fixture
make_dsdt 0x0107200A
make_managed_state s5 0x0107200A
printf 'quiet omen_acpi.variant=s5\n' > "$fixture/proc/cmdline"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: Table Upgrade: override [DSDT-HPQOEM-8E35    ]' \
    'ACPI: Table Upgrade: install [SSDT-EXAMPLE-TEST    ]' \
    > "$work/dmesg.log"
expect_state unknown
expect_probe_value REASON additional-acpi-override
expect_probe_value LOG_OTHER_ACPI 1

printf '256\n' > "$fixture/proc/sys/kernel/tainted"
expect_state unknown

printf '0\n' > "$fixture/proc/sys/kernel/tainted"
printf 'quiet omen_acpi.variant=s5 omen_acpi.variant=s5\n' > "$fixture/proc/cmdline"
expect_state unknown
expect_probe_value BOOT_MARKER invalid

printf 'quiet omen_acpi.variant=s5 omen_acpi.variant=combined\n' > "$fixture/proc/cmdline"
expect_state unknown
expect_probe_value BOOT_MARKER invalid

reset_probe_fixture
make_dsdt 0x0107200A
printf 'quiet omen_acpi.variant=s5\n' > "$fixture/proc/cmdline"
printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: Table Upgrade: override [DSDT-HPQOEM-8E35    ]' \
    > "$work/dmesg.log"
expect_state unknown

reset_probe_fixture
make_dsdt 0x01072009
: > "$work/dmesg.log"
printf '256\n' > "$fixture/proc/sys/kernel/tainted"
expect_state unknown

printf '0\n' > "$fixture/proc/sys/kernel/tainted"
printf '%s\n' 'ACPI: Table Upgrade: override [SSDT-EXAMPLE-TEST    ]' > "$work/dmesg.log"
expect_state unknown
expect_probe_value LOG_EARLY_ACPI 0
expect_probe_value LOG_OTHER_ACPI 1

printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: Table Upgrade: install [SSDT-EXAMPLE-TEST    ]' \
    > "$work/dmesg.log"
expect_state unknown

printf '%s\n' \
    'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' \
    'ACPI: SSDT ACPI table found in initrd [kernel/firmware/acpi/SSDT.aml][0x24]' \
    > "$work/dmesg.log"
expect_state stock
expect_probe_value LOG_CANDIDATE 1

: > "$work/dmesg.log"
printf 'quiet splash\n' > "$fixture/proc/cmdline"
make_dsdt 0x01072009
expect_state unavailable

printf '%s\n' 'ACPI: DSDT 0x0000000000000000 000024 (v02 HPQOEM 8E35)' > "$work/dmesg.log"
python3 - "$fixture/sys/firmware/acpi/tables/DSDT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[-1] ^= 1
path.write_bytes(data)
PY
expect_state unknown

printf 'manager legacy-state parser checks...\n'
sed '$d' "$ROOT/scripts/03-manage-limine-entry.sh" > "$work/manager-functions.sh"
(
    export OMEN_ACPI_TESTING=1
    # shellcheck disable=SC1090
    source "$work/manager-functions.sh"
    reset_probe_fixture
    make_dsdt 0x0107200A
    make_legacy_state s5
    select_variant s5
    STATE_DIR="$fixture/var/lib/omen-acpi-s5-test"
    metadata="$(legacy_state_metadata)" \
        || fail "manager rejected exact legacy state"
    [[ "${metadata%%$'\t'*}" == "$(sha256sum -- "$STATE_DIR/DSDT-S5-test.aml" | awk '{print $1}')" ]] \
        || fail "manager legacy AML fingerprint"
    cp -- "$STATE_DIR/SHA256SUMS" "$work/legacy-SHA256SUMS.good"
    sed -i '3s/omen-s5-test\.A1b2C3/omen-s5-test.Z9y8X7/' "$STATE_DIR/SHA256SUMS"
    if legacy_state_metadata >/dev/null 2>&1; then
        fail "manager accepted divergent legacy temporary roots"
    fi
    mv -- "$work/legacy-SHA256SUMS.good" "$STATE_DIR/SHA256SUMS"
    printf '%s\n' unexpected > "$STATE_DIR/extra.file"
    if legacy_state_metadata >/dev/null 2>&1; then
        fail "manager accepted a mixed legacy state"
    fi
    rm -f -- "$STATE_DIR/extra.file"

    legacy_esp="$work/legacy-esp"
    legacy_dropin="$work/legacy-dropin.conf"
    validation_work="$work/legacy-validation"
    mkdir -p "$legacy_esp" "$validation_work"
    printf 'normal kernel\n' > "$legacy_esp/normal-kernel"
    printf 'normal initramfs\n' > "$legacy_esp/normal-initramfs"
    printf 'legacy kernel\n' > "$legacy_esp/legacy-kernel"
    printf 'legacy initramfs\n' > "$legacy_esp/legacy-initramfs"
    chmod 0600 "$legacy_esp"/*
    cat > "$legacy_esp/limine.conf" <<'EOF'
/CachyOS
//linux-cachyos
    protocol: linux
    kernel_path: boot():/normal-kernel
    cmdline: quiet splash
    module_path: boot():/normal-initramfs
//zz-omen-acpi-s5-test
    comment: Legacy OMEN S5 test entry
    comment: Generated by limine-entry-tool
    protocol: linux
    kernel_path: boot():/legacy-kernel
    cmdline: quiet splash
    module_path: boot():/legacy-initramfs
//Snapshots
///46 | 2026-07-31 12:00:00
////linux-cachyos
    protocol: linux
    kernel_path: boot():/snapshot-normal-kernel
    cmdline: snapshot-root quiet
    module_path: boot():/snapshot-normal-initramfs
////zz-omen-acpi-s5-test
    comment: Historical snapshot copy; not an active entry
    protocol: linux
    protocol: linux
    kernel_path: boot():/snapshot-legacy-kernel
    cmdline: snapshot-root quiet
    module_path: boot():/snapshot-legacy-initramfs
EOF
    chmod 0600 "$legacy_esp/limine.conf"
    cat > "$legacy_dropin" <<'EOF'
# Creato da install-omen-s5-limine-test.sh
KERNEL_CMDLINE["zz-omen-acpi-s5-test"]="quiet splash"
EOF
    chmod 0600 "$legacy_dropin"
    DROPIN="$legacy_dropin"
    aml_hash="$(sha256sum -- "$STATE_DIR/DSDT-S5-test.aml" | awk '{print $1}')"
    initramfs_hash="$(sha256sum -- "$legacy_esp/legacy-initramfs" | awk '{print $1}')"
    external_source="$work/changed-external-source.tar.gz"
    printf '%s\n' 'changed after legacy installation' > "$external_source"
    printf '%s\n' "$external_source" > "$STATE_DIR/source-archive.txt"
    {
        printf '%064d  %s\n' 0 "$external_source"
        printf '%s  /var/tmp/omen-s5-test.A1b2C3/build/DSDT-OMEN-F13-S5-test.aml\n' "$aml_hash"
        printf '%s  /var/tmp/omen-s5-test.A1b2C3/initramfs-omen-acpi-s5-test.img\n' "$initramfs_hash"
    } > "$STATE_DIR/SHA256SUMS"
    validate_legacy_installation "$legacy_esp" "$validation_work" \
        || fail "manager rejected exact legacy entry and drop-in"
    [[ "$(config_entry_count "$legacy_esp/limine.conf")" == "1" ]] \
        || fail "manager counted snapshot copies as active reserved entries"
    extract_normal_entry "$legacy_esp/limine.conf" "$validation_work/normal-entry.txt" \
        || fail "manager rejected hierarchical normal entry"
    mapfile -t normal_entry < "$validation_work/normal-entry.txt"
    [[ "${normal_entry[0]}" == 'linux-cachyos' \
        && "${normal_entry[1]}" == 'boot():/normal-kernel' \
        && "${normal_entry[2]}" == 'quiet splash' \
        && "${normal_entry[3]}" == 'boot():/normal-initramfs' ]] \
        || fail "manager selected a snapshot instead of the active normal entry"

    generated_dropin="$work/generated-managed-dropin.conf"
    write_dropin_file "$generated_dropin" 'quiet splash root=UUID=test-value'
    grep -Fxq \
        'KERNEL_CMDLINE["zz-omen-acpi-s5-test"]="quiet splash root=UUID=test-value"' \
        "$generated_dropin" \
        || fail "managed drop-in is not JSON double-quoted"
    if grep -Fq "omen_acpi.variant=" "$generated_dropin" \
        || grep -Fq "='" "$generated_dropin"; then
        fail "managed drop-in retained a variant marker or literal shell quotes"
    fi

    expect_reserved_entry_rejected() {
        local label="$1"
        local options="$2"
        local config="$work/reserved-$label.conf"
        local output="$work/reserved-$label.txt"

        {
            printf '/Linux-CachyOS\n'
            printf '    protocol: linux\n'
            printf '    kernel_path: boot():/normal-kernel\n'
            printf '    cmdline: quiet\n'
            printf '    module_path: boot():/normal-initramfs\n'
            printf '/zz-omen-acpi-s5-test\n'
            printf '%s' "$options"
        } > "$config"
        if extract_exact_entry "$config" 'zz-omen-acpi-s5-test' "$output" \
            >/dev/null 2>&1; then
            fail "manager accepted unsafe reserved entry: $label"
        fi
    }

    expect_reserved_entry_rejected duplicate-protocol $'    protocol: linux\n    protocol: linux\n    kernel_path: boot():/kernel\n    cmdline: quiet\n    module_path: boot():/initramfs\n'
    expect_reserved_entry_rejected duplicate-kernel $'    protocol: linux\n    kernel_path: boot():/kernel\n    kernel_path: boot():/kernel\n    cmdline: quiet\n    module_path: boot():/initramfs\n'
    expect_reserved_entry_rejected kernel-aliases $'    protocol: linux\n    kernel_path: boot():/kernel\n    path: boot():/kernel\n    cmdline: quiet\n    module_path: boot():/initramfs\n'
    expect_reserved_entry_rejected duplicate-cmdline $'    protocol: linux\n    kernel_path: boot():/kernel\n    cmdline: quiet\n    cmdline: quiet\n    module_path: boot():/initramfs\n'
    expect_reserved_entry_rejected cmdline-aliases $'    protocol: linux\n    kernel_path: boot():/kernel\n    cmdline: quiet\n    kernel_cmdline: quiet\n    module_path: boot():/initramfs\n'
    expect_reserved_entry_rejected duplicate-module $'    protocol: linux\n    kernel_path: boot():/kernel\n    cmdline: quiet\n    module_path: boot():/initramfs\n    module_path: boot():/initramfs\n'

    printf '%s\n' \
        '# Creato da install-omen-s5-limine-test.sh' \
        'KERNEL_CMDLINE["zz-omen-acpi-s5-test"]="quiet splash omen_acpi.variant=s5"' \
        > "$legacy_dropin"
    if (validate_legacy_installation "$legacy_esp" "$validation_work") >/dev/null 2>&1; then
        fail "manager accepted a marker-modified legacy drop-in"
    fi

    cleanup_trace="$work/manager-cleanup-trace.txt"
    safe_remove_temp_dir() {
        printf '%s\n' "${1:-}" >> "$cleanup_trace"
    }

    : > "$cleanup_trace"
    set +e
    (
        arm_override_cleanup \
            /var/tmp/omen-acpi-override.cleanup-test \
            /var/lib/.omen-acpi-override-state.cleanup-test
        exit 73
    )
    cleanup_status=$?
    set -e
    [[ "$cleanup_status" == "73" ]] \
        || fail "manager cleanup trap changed the original exit status"
    mapfile -t cleanup_paths < "$cleanup_trace"
    [[ "${#cleanup_paths[@]}" == "2" \
        && "${cleanup_paths[0]}" == '/var/tmp/omen-acpi-override.cleanup-test' \
        && "${cleanup_paths[1]}" == '/var/lib/.omen-acpi-override-state.cleanup-test' ]] \
        || fail "manager cleanup trap lost globally retained staging paths"

    : > "$cleanup_trace"
    set +e
    (
        arm_override_cleanup \
            /var/tmp/omen-acpi-override.cleanup-preserve-test \
            /var/lib/.omen-acpi-override-state.cleanup-preserve-test
        preserve_override_candidate
        exit 74
    )
    cleanup_status=$?
    set -e
    [[ "$cleanup_status" == "74" ]] \
        || fail "manager preserving cleanup trap changed the exit status"
    mapfile -t cleanup_paths < "$cleanup_trace"
    [[ "${#cleanup_paths[@]}" == "1" \
        && "${cleanup_paths[0]}" == '/var/tmp/omen-acpi-override.cleanup-preserve-test' ]] \
        || fail "manager cleanup trap did not preserve an unsafe candidate"
)

printf 'fingerprint plumbing checks...\n'
grep -Fq 'dumped_dsdt_sha' "$ROOT/scripts/01-collect-acpi.sh" \
    || fail "collector live DSDT fingerprint check"
grep -Fq 'ORIGINAL_DSDT_SHA256=%s' "$ROOT/scripts/02-build-dsdt.sh" \
    || fail "builder fingerprint propagation"
grep -Fq 'different stock DSDT' "$ROOT/scripts/03-manage-limine-entry.sh" \
    || fail "manager stock DSDT fingerprint check"
python3 - "$ROOT/omen-acpi" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'^prepare_stock_recovery\(\) \{\n(?P<body>.*?)^\}', source,
                  flags=re.MULTILINE | re.DOTALL)
if match is None:
    raise SystemExit("prepare_stock_recovery function is missing")
body = match.group("body")
dependency = body.find("ensure_dependencies stock-recovery")
administrator = body.find("ensure_admin")
execution = body.find('stock_recovery_manager prepare')
if min(dependency, administrator, execution) < 0 or not dependency < administrator < execution:
    raise SystemExit("standalone stock preparation does not check dependencies before sudo execution")
wrapper = re.search(r'^stock_recovery_manager\(\) \{\n(?P<body>.*?)^\}', source,
                    flags=re.MULTILINE | re.DOTALL)
if wrapper is None or '"$SUDO_BIN" -- "$STOCK_RECOVERY" "$@"' not in wrapper.group("body"):
    raise SystemExit("stock recovery wrapper does not invoke the Python manager through sudo")
PY

printf 'partial-installation repair checks...\n'
install_help="$("$ROOT/install.sh" --help)"
grep -Fq -- '--repair' <<<"$install_help" \
    || fail "installer help does not document --repair"
if "$ROOT/install.sh" --unknown-test-option >"$work/install.out" 2>"$work/install.err"; then
    fail "installer accepted an unknown option"
fi
grep -Fq 'Unknown option' "$work/install.err" \
    || fail "installer did not reject an unknown option with a usage error"
grep -Fq 'rerun this installer with --repair' "$ROOT/install.sh" \
    || fail "partial-installation guard does not point at the repair path"
grep -Fq 'install.sh --repair' "$ROOT/uninstall.sh" \
    || fail "uninstaller does not point at the repair path"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

installer = (Path(sys.argv[1]) / "install.sh").read_text(encoding="utf-8")

# The sudo re-exec must forward the original arguments, otherwise --repair is
# silently dropped when install.sh is started as a normal user.
if 'original_arguments=("$@")' not in installer:
    raise SystemExit("install.sh does not save its original arguments")
if not re.search(
    r'exec /usr/bin/sudo -- "\$\(realpath -- "\$0"\)" \\\n\s*'
    r'\$\{original_arguments\[@\]\+"\$\{original_arguments\[@\]\}"\}',
    installer,
):
    raise SystemExit("install.sh sudo re-exec does not forward its arguments")

# Each of the three targets must be backed up independently so that a partial
# installation can be rebuilt transactionally.
for target in ("TARGET_ROOT", "TARGET_DOC", "TARGET_BIN"):
    if f'if path_exists "${target}"; then' not in installer:
        raise SystemExit(f"install.sh does not guard the {target} backup individually")

print("partial-installation repair wiring: PASS")
PY

printf 'pre-uninstall orphan checks...\n'
pre_uninstall_fixture="$work/pre-uninstall"
mkdir -p "$pre_uninstall_fixture/esp"
printf 'timeout: 5\n/Linux-CachyOS\n' > "$pre_uninstall_fixture/esp/limine.conf"
sed '$d' "$ROOT/scripts/03-manage-limine-entry.sh" > "$pre_uninstall_fixture/manager-functions.sh"
for kind in directory broken-symlink; do
    payload="$pre_uninstall_fixture/esp/omen-acpi-stock-recovery"
    if [[ "$kind" == directory ]]; then
        mkdir "$payload"
        printf 'foreign\n' > "$payload/foreign.bin"
    else
        ln -s "$pre_uninstall_fixture/missing-target" "$payload"
    fi
    if TEST_ESP="$pre_uninstall_fixture/esp" \
        bash -c '
            source "$1"
            require_root() { :; }
            acquire_lock() { :; }
            find_esp() { printf "%s\\n" "$TEST_ESP"; }
            pre_uninstall_check_action
        ' _ "$pre_uninstall_fixture/manager-functions.sh" \
        >"$work/pre-uninstall-$kind.out" 2>"$work/pre-uninstall-$kind.err"; then
        fail "pre-uninstall accepted an orphan recovery payload ($kind)"
    fi
    grep -Fq 'Incomplete stock-recovery state' "$work/pre-uninstall-$kind.err" \
        || fail "pre-uninstall did not diagnose orphan recovery payload ($kind)"
    [[ -e "$payload" || -L "$payload" ]] \
        || fail "pre-uninstall deleted orphan recovery payload ($kind)"
    if [[ -L "$payload" ]]; then rm -f -- "$payload"; else rm -rf -- "$payload"; fi
done

printf 'transform checks...\n'
python3 "$ROOT/tests/test_transform.py"

printf 'stock recovery checks...\n'
python3 "$ROOT/tests/test_stock_recovery.py"

printf 'interactive menu checks...\n'
bash "$ROOT/tests/test_interactive_menus.sh"

printf 'release-builder mismatch and updater verify-only checks...\n'
version_fixture="$work/version-mismatch"
mkdir -p "$version_fixture"
cp -a "$ROOT/.github" "$ROOT/.gitignore" "$ROOT/CHANGELOG.md" "$ROOT/LICENSE" \
    "$ROOT/README.md" "$ROOT/SECURITY.md" "$ROOT/install.sh" "$ROOT/omen-acpi" \
    "$ROOT/patches" "$ROOT/scripts" "$ROOT/tests" "$ROOT/tools" \
    "$ROOT/uninstall.sh" "$ROOT/update.sh" "$ROOT/SHA256SUMS" "$version_fixture/"
sed -i 's/^VERSION = "2.1.11"$/VERSION = "9.9.9"/' \
    "$version_fixture/scripts/04-stock-recovery.py"
if "$version_fixture/tools/make-release.sh" "$work" >"$work/version-build.out" 2>"$work/version-build.err"; then
    fail "release builder accepted a divergent Python manager version"
fi
grep -Fq 'scripts/04-stock-recovery.py does not declare version 2.1.11' "$work/version-build.err" \
    || fail "release builder did not diagnose the Python manager mismatch"

release_output="$work/release"
mkdir -p "$release_output" "$work/verify-home"
"$ROOT/tools/make-release.sh" "$release_output" >"$work/release-build.out"
HOME="$work/verify-home" XDG_DATA_HOME="$work/verify-home/.local/share" \
    "$ROOT/update.sh" --verify-only --archive \
    "$release_output/omen-acpi-toolkit-v2.1.11.tar.gz" >"$work/verify-only.out"
grep -Fq 'Verification completed; installation was not started.' "$work/verify-only.out" \
    || fail "updater verify-only did not complete verification"
if find "$work/verify-home" -mindepth 1 -print -quit | grep -q .; then
    fail "updater verify-only created persistent HOME content"
fi

mismatch_root="$work/updater-version-mismatch"
mkdir -p "$mismatch_root/extracted" "$mismatch_root/assets" "$work/mismatch-home"
tar -xzf "$release_output/omen-acpi-toolkit-v2.1.11.tar.gz" -C "$mismatch_root/extracted"
mismatch_release="$mismatch_root/extracted/omen-acpi-toolkit-v2.1.11"
sed -i 's/^VERSION = "2.1.11"$/VERSION = "9.9.9"/' \
    "$mismatch_release/scripts/04-stock-recovery.py"
mismatch_hash="$(sha256sum "$mismatch_release/scripts/04-stock-recovery.py" | awk '{print $1}')"
sed -i "s|^[0-9a-f]\{64\}  scripts/04-stock-recovery.py$|$mismatch_hash  scripts/04-stock-recovery.py|" \
    "$mismatch_release/SHA256SUMS"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-08-01 00:00:00' \
    -czf "$mismatch_root/assets/omen-acpi-toolkit-v2.1.11.tar.gz" \
    -C "$mismatch_root/extracted" omen-acpi-toolkit-v2.1.11
( cd "$mismatch_root/assets" && sha256sum omen-acpi-toolkit-v2.1.11.tar.gz \
    > omen-acpi-toolkit-v2.1.11.tar.gz.sha256 )
if HOME="$work/mismatch-home" "$ROOT/update.sh" --verify-only --archive \
    "$mismatch_root/assets/omen-acpi-toolkit-v2.1.11.tar.gz" \
    >"$work/updater-mismatch.out" 2>"$work/updater-mismatch.err"; then
    fail "updater accepted a divergent Python manager version"
fi
grep -Fq 'version mismatch in scripts/04-stock-recovery.py' "$work/updater-mismatch.err" \
    || fail "updater did not diagnose the Python manager mismatch"
if find "$work/mismatch-home" -mindepth 1 -print -quit | grep -q .; then
    fail "failed updater verify-only created persistent HOME content"
fi

printf 'all tests: PASS\n'
