#!/usr/bin/env python3
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail-closed preventive stock-boot recovery manager.

All mutable paths can be redirected below OMEN_ACPI_TEST_ROOT.  Production
invocations deliberately have no option for selecting arbitrary paths.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile

VERSION = "2.3.0"
OWNED_SNAPSHOT_VERSIONS = {"2.1.10", "2.1.11", "2.2.0", "2.3.0"}
TRUSTED_SNAPSHOT_VERSIONS = {"2.1.11", "2.2.0", "2.3.0"}
SCHEMA = 1
ENTRY = "zz-omen-acpi-stock-recovery"
BEGIN = "# BEGIN OMEN-ACPI OWNED STOCK RECOVERY v1"
END = "# END OMEN-ACPI OWNED STOCK RECOVERY v1"
EXPECTED = ("OMEN Gaming Laptop 16-ap0xxx", "8E35", "F.13")
STOCK_REVISION = "0x01072009"
VARIANT_MARKERS = ("omen_acpi.variant=",)
SUPPORTED_KERNELS = ("linux-cachyos", "linux-cachyos-lts")


class Failure(RuntimeError):
    pass


# Filesystem and process safety

def rooted(path: str) -> Path:
    root = os.environ.get("OMEN_ACPI_TEST_ROOT")
    if root:
        return Path(root) / path.lstrip("/")
    return Path(path)


def recovery_state_path() -> Path:
    return rooted("/var/lib/omen-acpi-stock-recovery")


def manager_lock_path() -> Path:
    return rooted("/run/omen-acpi-fix/manager.lock")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular_file(
    path: Path, *, owner: int | None = None, links: int = 1
) -> os.stat_result:
    try:
        before = path.lstat()
    except OSError as error:
        raise Failure(f"cannot inspect regular file {path}: {error}") from error
    if not stat.S_ISREG(before.st_mode) or path.is_symlink():
        raise Failure(f"unsafe non-regular file: {path}")
    if owner is not None and before.st_uid != owner:
        raise Failure(f"unexpected owner for {path}")
    if before.st_nlink != links:
        raise Failure(f"unexpected hard-link count for {path}")
    return before


def require_secure_directory(path: Path, *, mode: int = 0o700) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise Failure(f"cannot inspect directory {path}: {error}") from error
    expected_owner = os.geteuid() if os.environ.get("OMEN_ACPI_TEST_ROOT") else 0
    if not stat.S_ISDIR(info.st_mode) or path.is_symlink() or info.st_uid != expected_owner:
        raise Failure(f"unsafe directory: {path}")
    if stat.S_IMODE(info.st_mode) != mode:
        raise Failure(f"unsafe mode for {path}: {stat.S_IMODE(info.st_mode):04o}")


def directory_identity(path: Path, *, mode: int = 0o700) -> tuple[int, ...]:
    require_secure_directory(path, mode=mode)
    info = path.lstat()
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns, stat.S_IMODE(info.st_mode))


def fsync_file(path: Path) -> None:
    with path.open("rb", buffering=0) as stream:
        os.fsync(stream.fileno())


def fsync_dir(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def cleanup_tree(path: Path, point: str) -> None:
    if (os.environ.get("OMEN_ACPI_TEST_ROOT") and
            os.environ.get("OMEN_ACPI_TEST_FAIL_CLEANUP") == point):
        raise OSError(f"simulated cleanup failure at {point}")
    shutil.rmtree(path)


def cleanup_file(path: Path, point: str) -> None:
    if (os.environ.get("OMEN_ACPI_TEST_ROOT") and
            os.environ.get("OMEN_ACPI_TEST_FAIL_CLEANUP") == point):
        raise OSError(f"simulated cleanup failure at {point}")
    path.unlink()


def require_absent(*paths: Path) -> None:
    for path in paths:
        if path_present(path):
            raise Failure(f"transaction destination already exists: {path}")


def rename_noreplace(source: Path, target: Path) -> None:
    """Atomically rename without ever replacing an existing directory entry."""
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise Failure("renameat2(RENAME_NOREPLACE) is unavailable")
    renameat2.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                          ctypes.c_char_p, ctypes.c_uint)
    renameat2.restype = ctypes.c_int
    if renameat2(-100, os.fsencode(source), -100, os.fsencode(target), 1) != 0:
        error_number = ctypes.get_errno()
        if error_number == errno.EEXIST:
            raise Failure(f"transaction destination appeared concurrently: {target}")
        raise OSError(error_number, os.strerror(error_number), str(source), str(target))


def acquire_lock():
    path = manager_lock_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink():
        raise Failure("unsafe lock directory")
    os.chmod(path.parent, 0o700)
    stream = path.open("a+")
    fcntl.flock(stream, fcntl.LOCK_EX)
    return stream


def read_machine() -> tuple[str, str, str]:
    values = []
    for name in ("product_name", "board_name", "bios_version"):
        path = rooted(f"/sys/class/dmi/id/{name}")
        values.append(path.read_text(encoding="utf-8").strip())
    result = tuple(values)
    if len(result) != 3 or not all(result) or any("\n" in value or "\r" in value for value in result):
        raise Failure("DMI identity is missing, empty or unreadable")
    return result  # type: ignore[return-value]


def require_transform_machine() -> tuple[str, str, str]:
    result = read_machine()
    if result != EXPECTED and os.environ.get("OMEN_ACPI_UNVALIDATED_OPT_IN") != "1":
        raise Failure(f"unsupported machine: product={result[0]!r}, board={result[1]!r}, BIOS={result[2]!r}")
    return result


# Limine and normal-entry parsing

def resolve_esp_path() -> Path:
    override = os.environ.get("OMEN_ACPI_TEST_ESP")
    if override:
        esp = Path(override).resolve()
    else:
        result = subprocess.run(["bootctl", "--print-esp-path"], text=True, capture_output=True)
        candidates = [result.stdout.strip()]
        defaults = Path("/etc/default/limine")
        if defaults.is_file() and not defaults.is_symlink():
            values = []
            for raw in defaults.read_text(encoding="utf-8", errors="strict").splitlines():
                line = raw.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    if key.strip() == "ESP_PATH":
                        parsed = shlex.split(value, comments=True, posix=True)
                        if len(parsed) != 1:
                            raise Failure("ESP_PATH is not one literal path")
                        values.append(parsed[0])
            if len(values) > 1:
                raise Failure("ESP_PATH is defined more than once")
            candidates.extend(values)
        candidates.append("/boot")
        esp = next((Path(item).resolve() for item in candidates if item and (Path(item) / "limine.conf").is_file()), None)
        if esp is None:
            raise Failure("could not locate the Limine filesystem")
        mount = subprocess.run(["findmnt", "-nro", "TARGET", "-T", str(esp)], text=True, capture_output=True)
        targets = mount.stdout.splitlines()
        if not targets or Path(targets[0]).resolve() != esp:
            raise Failure("the Limine directory is not a distinct mounted filesystem")
    require_secure_directory(esp, mode=stat.S_IMODE(esp.stat().st_mode))
    config = esp / "limine.conf"
    require_regular_file(config)
    return esp


ENTRY_RE = re.compile(r"^\s*(/+)(\+?)([^/].*)$")
OPTION_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$")


def parse_limine_entries(text: str) -> list[dict]:
    lines = text.splitlines()
    found: list[dict] = []
    stack: list[int] = []
    for index, line in enumerate(lines):
        match = ENTRY_RE.match(line)
        if not match:
            continue
        level = len(match.group(1))
        while stack and found[stack[-1]]["level"] >= level:
            stack.pop()
        found.append({"start": index, "level": level, "parent": stack[-1] if stack else None,
                      "title": match.group(3).strip()})
        stack.append(len(found) - 1)
    for index, item in enumerate(found):
        item["end"] = found[index + 1]["start"] if index + 1 < len(found) else len(lines)
        options: dict[str, str] = {}
        modules: list[str] = []
        comments: list[str] = []
        for line in lines[item["start"] + 1:item["end"]]:
            match = OPTION_RE.match(line)
            if not match:
                continue
            key, value = match.group(1).lower(), match.group(2)
            if key == "module_path":
                modules.append(value)
            elif key == "comment":
                comments.append(value)
            else:
                if key in options:
                    item["duplicate"] = key
                options[key] = value
        item.update(options=options, modules=modules, comments=comments,
                    block="\n".join(lines[item["start"]:item["end"]]))
    return found


def boot_fields(item: dict) -> tuple[str, str, list[str]]:
    options = item["options"]
    kernels = [key for key in ("kernel_path", "path") if key in options]
    commands = [key for key in ("cmdline", "kernel_cmdline") if key in options]
    if item.get("duplicate") or options.get("protocol", "").lower() != "linux" or len(kernels) != 1 or len(commands) > 1 or not item["modules"]:
        raise Failure(f"malformed Limine entry: {item['title']}")
    command = options[commands[0]] if commands else ""
    command = re.sub(r"(?<!\S)(?:initrd|BOOT_IMAGE)=[^\s]+", "", command)
    command = re.sub(r"\s+", " ", command).strip()
    return options[kernels[0]], command, item["modules"]


def normal_entries(text: str) -> list[dict]:
    found = parse_limine_entries(text)
    candidates = []
    namespace = None

    def historical(item: dict) -> bool:
        parent = item["parent"]
        while parent is not None:
            ancestor = found[parent]
            if "snapshot" in ancestor["title"].lower():
                return True
            parent = ancestor["parent"]
        return False

    for kernel_id in SUPPORTED_KERNELS:
        named = []
        for item in found:
            markers = [
                value.split("=", 1)[1].lower()
                for value in item["comments"]
                if value.lower().startswith("kernel-id=")
            ]
            if len(markers) > 1:
                raise Failure(f"normal CachyOS entry {item['title']!r} has duplicate kernel-id markers")
            if item["title"].lower() == kernel_id and markers and markers != [kernel_id]:
                raise Failure(f"normal CachyOS entry {item['title']!r} has a conflicting kernel-id marker")
            if item["title"].lower() != kernel_id and markers != [kernel_id]:
                continue
            if not historical(item):
                named.append(item)
        if len(named) > 1:
            raise Failure(f"normal CachyOS entry {kernel_id!r} is ambiguous")
        if not named:
            continue
        item = named[0]
        current_namespace = (item["level"], item["parent"])
        if namespace is None:
            namespace = current_namespace
        elif namespace != current_namespace:
            raise Failure("normal CachyOS entries do not share one active namespace")
        item["kernel_id"] = kernel_id
        candidates.append(item)
    if not candidates:
        inferred = {}
        for item in found:
            searchable = f"{item['title']}\n{item['block']}".lower()
            if (
                "linux-cachyos" not in searchable
                or historical(item)
                or any(word in searchable for word in ("fallback", "snapshot", "omen-acpi"))
            ):
                continue
            kernel_id = (
                "linux-cachyos-lts"
                if "linux-cachyos-lts" in searchable
                else "linux-cachyos"
            )
            if kernel_id in inferred:
                raise Failure(f"normal CachyOS entry {kernel_id!r} is ambiguous")
            inferred[kernel_id] = item
        for kernel_id in SUPPORTED_KERNELS:
            if kernel_id in inferred:
                item = inferred[kernel_id]
                current_namespace = (item["level"], item["parent"])
                if namespace is None:
                    namespace = current_namespace
                elif namespace != current_namespace:
                    raise Failure("normal CachyOS entries do not share one active namespace")
                item["kernel_id"] = kernel_id
                candidates.append(item)
    valid = []
    for item in candidates:
        try:
            boot_fields(item)
            valid.append(item)
        except Failure:
            if item["title"].lower() in SUPPORTED_KERNELS:
                raise
    return valid


def normal_entry(text: str, *, required: bool = True) -> dict | None:
    valid = normal_entries(text)
    if not valid:
        if required:
            raise Failure("normal CachyOS entry is missing")
        return None
    return valid[0]


def resolve_limine_path(value: str, esp: Path) -> tuple[Path, str]:
    value = value.split("#", 1)[0].strip()
    if value.startswith("$"):
        value = value[1:]
    match = re.fullmatch(r"boot\(\):/([^\x00\r\n]+)", value)
    if not match:
        raise Failure(f"unsupported or absolute Limine path: {value}")
    pure = PurePosixPath(match.group(1))
    if not pure.parts or any(part in ("", ".", "..") for part in pure.parts):
        raise Failure(f"noncanonical or traversing Limine path: {value}")
    candidate = esp.joinpath(*pure.parts)
    cursor = esp
    for part in pure.parts[:-1]:
        cursor /= part
        if (cursor.exists() or cursor.is_symlink()) and cursor.is_symlink():
            raise Failure(f"symlinked Limine path component rejected: {value}")
    resolved_parent = candidate.parent.resolve()
    if resolved_parent != esp and esp not in resolved_parent.parents:
        raise Failure(f"Limine path escapes its filesystem: {value}")
    return candidate, "boot():/" + pure.as_posix()


def probe_boot_state() -> dict[str, str]:
    script = Path(__file__).with_name("00-probe-boot.sh")
    result = subprocess.run([str(script), "--env"], text=True, capture_output=True, env=os.environ)
    if result.returncode:
        raise Failure("the current ACPI state could not be verified")
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return values


def copy_stable(source: Path, target: Path,
                expected: tuple[tuple[int, int, int, int, int, int], str]) -> str:
    before = require_regular_file(source)
    before_identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                       before.st_ctime_ns, stat.S_IMODE(before.st_mode))
    if before_identity != expected[0]:
        raise Failure(f"source identity changed after validation: {source}")
    with source.open("rb", buffering=0) as incoming, target.open("xb", buffering=0) as outgoing:
        shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    after = require_regular_file(source)
    after_identity = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
                      after.st_ctime_ns, stat.S_IMODE(after.st_mode))
    if before_identity != after_identity:
        raise Failure(f"source changed during copy: {source}")
    source_digest = sha256_file(source)
    target_digest = sha256_file(target)
    if source_digest != expected[1]:
        raise Failure(f"source digest changed after validation: {source}")
    if target_digest != expected[1]:
        raise Failure(f"copy verification failed: {source}")
    return target_digest


def file_identity(path: Path, expected: bytes | None = None) -> tuple[int, int, int, int, int, int]:
    """Return an ESP-friendly identity and optionally require exact bytes."""
    info = require_regular_file(path)
    content = path.read_bytes()
    after = require_regular_file(path)
    identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                info.st_ctime_ns, stat.S_IMODE(info.st_mode))
    if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
                    after.st_ctime_ns, stat.S_IMODE(after.st_mode)):
        raise Failure(f"file changed while inspected: {path}")
    if expected is not None and content != expected:
        raise Failure(f"file changed before commit: {path}")
    return identity


def write_exclusive(path: Path, content: bytes, mode: int) -> tuple[int, int, int, int, int, int]:
    """Create one transaction file without following or replacing any entry."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, mode)
    except OSError as error:
        if error.errno in (errno.EEXIST, errno.ELOOP, errno.EISDIR):
            raise Failure(f"transaction file appeared concurrently: {path}") from error
        raise
    created = os.fstat(descriptor)
    completed = False
    try:
        os.fchmod(descriptor, mode)
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError(errno.EIO, "short write", str(path))
            view = view[written:]
        os.fsync(descriptor)
        completed = True
    finally:
        os.close(descriptor)
        if not completed:
            try:
                current = path.lstat()
                if (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
                    path.unlink()
            except FileNotFoundError:
                pass
    return file_identity(path, content)


def inspect_source_initramfs(path: Path, managed_hashes: set[str]) -> None:
    """Reject ACPI overrides and any payload identical to a managed variant."""
    if sha256_file(path) in managed_hashes:
        raise Failure(f"managed variant initramfs was renamed as a stock module: {path}")
    command = os.environ.get("OMEN_ACPI_TEST_LSINITCPIO", "lsinitcpio")
    try:
        result = subprocess.run([command, "-l", str(path)], text=True,
                                capture_output=True, check=False)
    except OSError as error:
        raise Failure(f"cannot inspect initramfs {path}: {error}") from error
    if result.returncode:
        raise Failure(f"lsinitcpio could not inspect source initramfs: {path}")
    members = [line.strip().lstrip("./") for line in result.stdout.splitlines()]
    forbidden = [item for item in members if item == "kernel/firmware/acpi" or
                 item.startswith("kernel/firmware/acpi/")]
    if forbidden:
        raise Failure(f"ACPI override content found in source initramfs: {path}")


def path_present(path: Path) -> bool:
    """Treat every directory entry, including a broken symlink, as present."""
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    except OSError as error:
        raise Failure(f"cannot inspect managed recovery path {path}: {error}") from error
    return True


def stable_fingerprint(path: Path) -> tuple[tuple[int, int, int, int, int, int], str]:
    """Hash one regular single-link file while proving stable identity."""
    before = require_regular_file(path)
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                before.st_ctime_ns, stat.S_IMODE(before.st_mode))
    digest = sha256_file(path)
    after = require_regular_file(path)
    after_identity = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
                      after.st_ctime_ns, stat.S_IMODE(after.st_mode))
    if identity != after_identity:
        raise Failure(f"source changed while inspected: {path}")
    return identity, digest


def validate_normal_source(text: str, esp: Path, source: dict | None = None) -> dict:
    """Select and fully validate the normal entry and each referenced payload."""
    source = source if source is not None else normal_entry(text)
    assert source is not None
    kernel_value, command, modules = boot_fields(source)
    if any(marker in command for marker in VARIANT_MARKERS) or "omen_acpi.stock_recovery=" in command:
        raise Failure("normal entry contains an OMEN ACPI marker")
    kernel, kernel_canonical = resolve_limine_path(kernel_value, esp)
    module_pairs = [resolve_limine_path(item, esp) for item in modules]
    forbidden = ("omen-acpi-s5", "omen-acpi-combined", "DSDT.aml")
    for local, canonical in [(kernel, kernel_canonical), *module_pairs]:
        if any(token.lower() in canonical.lower() for token in forbidden):
            raise Failure(f"variant or ACPI-override payload rejected: {canonical}")

    known_hashes = managed_initramfs_hashes()
    fingerprints = []
    for local, canonical in [(kernel, kernel_canonical), *module_pairs]:
        before = stable_fingerprint(local)
        if local != kernel:
            inspect_source_initramfs(local, known_hashes)
        after = stable_fingerprint(local)
        if before != after:
            raise Failure(f"source changed during validation: {local}")
        fingerprints.append((canonical, *before))
    normalized = (source["title"], kernel_canonical,
                  tuple(item[1] for item in module_pairs), command)
    return {"entry": source, "kernel": kernel, "kernel_canonical": kernel_canonical,
            "command": command, "modules": module_pairs, "normalized": normalized,
            "fingerprints": tuple(fingerprints)}


def require_same_normal_source(text: str, esp: Path, initial: dict) -> dict:
    """Repeat every content check and require the original normalized source."""
    current = validate_normal_source(text, esp)
    if (current["normalized"] != initial["normalized"]
            or current["fingerprints"] != initial["fingerprints"]):
        raise Failure("normal CachyOS source changed during the removal transaction")
    return current


def require_normal_source_identities(esp: Path, initial: dict) -> None:
    """Quick final boundary check of identities already content-validated."""
    for canonical, expected_identity, _digest in initial["fingerprints"]:
        path, confirmed = resolve_limine_path(canonical, esp)
        if confirmed != canonical:
            raise Failure("normal CachyOS path changed after validation")
        info = require_regular_file(path)
        identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                    info.st_ctime_ns, stat.S_IMODE(info.st_mode))
        if identity != expected_identity:
            raise Failure(f"normal CachyOS payload changed at commit boundary: {path}")


def managed_initramfs_hashes() -> set[str]:
    hashes: set[str] = set()
    for variant in ("s5", "combined"):
        state = rooted(f"/var/lib/omen-acpi-{variant}-test")
        if not state.exists() and not state.is_symlink():
            continue
        require_secure_directory(state)
        checksum = state / "initramfs.sha256"
        payload = state / "initramfs.img"
        require_regular_file(checksum, owner=os.geteuid() if os.environ.get("OMEN_ACPI_TEST_ROOT") else 0)
        require_regular_file(payload, owner=os.geteuid() if os.environ.get("OMEN_ACPI_TEST_ROOT") else 0)
        value = checksum.read_text(encoding="ascii", errors="strict").strip()
        if not re.fullmatch(r"[0-9a-f]{64}", value):
            raise Failure(f"managed variant contains an invalid initramfs checksum: {checksum}")
        if sha256_file(payload) != value:
            raise Failure(f"managed variant initramfs checksum does not match its payload: {payload}")
        hashes.add(value)
    return hashes


def restore_config_if_unchanged(config: Path, backup: Path, installed: bytes,
                                backup_bytes: bytes, backup_identity: tuple) -> bool:
    """Restore only bytes installed by this transaction; preserve foreign edits."""
    try:
        if file_identity(backup, backup_bytes) != backup_identity:
            raise Failure("transaction backup changed before rollback")
    except Failure as error:
        print(f"WARNING: Limine rollback backup is no longer owned; rollback skipped: {error}",
              file=sys.stderr)
        return False
    try:
        file_identity(config, installed)
    except Failure:
        print("WARNING: Limine configuration changed after toolkit commit; external bytes were preserved.",
              file=sys.stderr)
        return False
    os.replace(backup, config)
    fsync_dir(config.parent)
    return True


def cleanup_owned_file(path: Path, identity: tuple | None, point: str | None = None) -> None:
    """Remove only the exact regular file created by this transaction."""
    if identity is None or not path_present(path):
        return
    if file_identity(path) != identity:
        raise Failure(f"transaction file changed; cleanup skipped: {path}")
    if point is None:
        path.unlink()
    else:
        cleanup_file(path, point)


def load_owned_snapshot(esp: Path | None = None, *, state_path: Path | None = None,
                        payload_path: Path | None = None,
                        require_current_machine: bool = True) -> dict:
    """Verify managed ownership, schema and integrity, but not boot trust."""
    state = state_path if state_path is not None else recovery_state_path()
    require_secure_directory(state)
    manifest_path = state / "manifest.json"
    if {item.name for item in state.iterdir()} != {"manifest.json"}:
        raise Failure("recovery state contains unexpected files")
    require_regular_file(manifest_path, owner=os.geteuid() if os.environ.get("OMEN_ACPI_TEST_ROOT") else 0)
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise Failure(f"invalid recovery metadata: {error}") from error
    required = {"schema", "toolkit_version", "created_utc", "machine", "dsdt", "source_entry",
                "kernel_version", "normalized_entry", "original_kernel_path", "original_module_paths",
                "command_line", "payload_root", "payloads", "stock_boot_verified", "snapshot_id"}
    if (set(data) != required or data["schema"] != SCHEMA
            or data["toolkit_version"] not in OWNED_SNAPSHOT_VERSIONS
            or data["stock_boot_verified"] is not True):
        raise Failure("recovery manifest schema or provenance is invalid")
    if not isinstance(data["machine"], dict) or set(data["machine"]) != {"product", "board", "bios"}:
        raise Failure("recovery snapshot machine identity is invalid")
    snapshot_machine = tuple(data["machine"][key] for key in ("product", "board", "bios"))
    if not all(isinstance(value, str) and value for value in snapshot_machine):
        raise Failure("recovery snapshot machine identity is invalid")
    if data["toolkit_version"] in {"2.1.10", "2.1.11"} and snapshot_machine != EXPECTED:
        raise Failure("recovery snapshot belongs to a different machine or BIOS")
    if require_current_machine and snapshot_machine != read_machine():
        raise Failure("recovery snapshot belongs to a different machine or BIOS")
    canonical_payload, canonical = resolve_limine_path(
        data["payload_root"], esp if esp is not None else resolve_esp_path()
    )
    if canonical != data["payload_root"] or canonical_payload.name != "omen-acpi-stock-recovery":
        raise Failure("invalid recovery payload root")
    payload_root = payload_path if payload_path is not None else canonical_payload
    require_secure_directory(payload_root)
    expected_names = {item["name"] for item in data["payloads"]}
    actual_names = {item.name for item in payload_root.iterdir()}
    if actual_names != expected_names:
        raise Failure("recovery payload directory is incomplete or contains foreign files")
    for item in data["payloads"]:
        if not re.fullmatch(r"(?:kernel|module-[0-9]{3})\.bin", item["name"]):
            raise Failure("invalid deterministic payload name")
        path = payload_root / item["name"]
        require_regular_file(path)
        if path.stat().st_size != item["size"] or sha256_file(path) != item["sha256"]:
            raise Failure(f"recovery payload was modified: {item['name']}")
    canonical_json = json.dumps({key: value for key, value in data.items() if key != "snapshot_id"}, sort_keys=True, separators=(",", ":")).encode()
    if hashlib.sha256(canonical_json).hexdigest() != data["snapshot_id"]:
        raise Failure("recovery metadata was modified")
    return data


def load_owned_snapshot_record(esp: Path, *, state_path: Path | None = None,
                               payload_path: Path | None = None,
                               require_current_machine: bool = True) -> tuple[dict, tuple]:
    """Load twice and bind an owned snapshot to exact directory/file identities."""
    state = state_path if state_path is not None else recovery_state_path()
    payload = payload_path if payload_path is not None else esp / "omen-acpi-stock-recovery"
    first = load_owned_snapshot(
        esp, state_path=state, payload_path=payload,
        require_current_machine=require_current_machine
    )

    def fingerprint(data: dict) -> tuple:
        components = [("manifest.json", *stable_fingerprint(state / "manifest.json"))]
        for item in sorted(data["payloads"], key=lambda entry: entry["name"]):
            components.append((item["name"], *stable_fingerprint(payload / item["name"])))
        return (data["snapshot_id"], directory_identity(state), directory_identity(payload),
                tuple(components))

    first_fingerprint = fingerprint(first)
    second = load_owned_snapshot(
        esp, state_path=state, payload_path=payload,
        require_current_machine=require_current_machine
    )
    second_fingerprint = fingerprint(second)
    if first["snapshot_id"] != second["snapshot_id"] or first_fingerprint != second_fingerprint:
        raise Failure("recovery snapshot changed while ownership was verified")
    return second, second_fingerprint


def load_trusted_snapshot(esp: Path | None = None) -> dict:
    """Return only snapshots created with the content checks in 2.1.11."""
    data = load_owned_snapshot(esp)
    if data["toolkit_version"] not in TRUSTED_SNAPSHOT_VERSIONS:
        raise Failure(
            "the recovery snapshot was created by 2.1.10 and is integrity-checked "
            "but untrusted for boot; refresh it from a clean stock boot"
        )
    return data


def load_trusted_snapshot_record(esp: Path) -> tuple[dict, tuple]:
    data, fingerprint = load_owned_snapshot_record(esp)
    if data["toolkit_version"] not in TRUSTED_SNAPSHOT_VERSIONS:
        raise Failure(
            "the recovery snapshot was created by 2.1.10 and is integrity-checked "
            "but untrusted for boot; refresh it from a clean stock boot"
        )
    return data, fingerprint


def existing_owned_snapshot(esp: Path, *, require_current_machine: bool = True) -> dict | None:
    """Require the reserved payload/state paths to be absent or a verified pair."""
    payload = esp / "omen-acpi-stock-recovery"
    state = recovery_state_path()
    payload_present = path_present(payload)
    state_present = path_present(state)
    if not payload_present and not state_present:
        return None
    if payload_present != state_present:
        raise Failure(
            "recovery payload and manifest state are incomplete; manual inspection is required"
        )
    return load_owned_snapshot(esp, require_current_machine=require_current_machine)


def existing_owned_snapshot_record(esp: Path, *,
                                   require_current_machine: bool = True) -> tuple[dict, tuple] | None:
    """Return the exact verified pair, or require both reserved paths absent."""
    existing = existing_owned_snapshot(esp, require_current_machine=require_current_machine)
    if existing is None:
        return None
    return load_owned_snapshot_record(esp, require_current_machine=require_current_machine)


def require_same_owned_snapshot(esp: Path, initial: tuple[dict, tuple] | None, *,
                                require_current_machine: bool = True) -> None:
    current = existing_owned_snapshot_record(
        esp, require_current_machine=require_current_machine
    )
    if initial is None:
        if current is not None:
            raise Failure("recovery state appeared during snapshot staging")
        return
    if current is None or current[0]["snapshot_id"] != initial[0]["snapshot_id"] \
            or current[1] != initial[1]:
        raise Failure("managed recovery snapshot changed during the transaction")


# Snapshot lifecycle

def prepare() -> None:
    product, board, bios = require_transform_machine()
    probe_state = probe_boot_state()
    if probe_state.get("STATE") != "stock" or probe_state.get("CLEAN") != "1":
        raise Failure(f"snapshot preparation requires a clean verified stock boot; current state is {probe_state.get('STATE', 'unavailable')}")
    esp = resolve_esp_path()
    config = esp / "limine.conf"
    config_before = require_regular_file(config)
    text = config.read_text(encoding="utf-8", errors="strict")
    source_data = validate_normal_source(text, esp)
    source = source_data["entry"]
    kernel = source_data["kernel"]
    kernel_canonical = source_data["kernel_canonical"]
    command = source_data["command"]
    module_pairs = source_data["modules"]
    payload = esp / "omen-acpi-stock-recovery"
    initial_snapshot = existing_owned_snapshot_record(esp)
    state_dir = recovery_state_path()
    state_dir.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    old_payload = esp / f".omen-acpi-stock-recovery.old.{os.getpid()}"
    old_state = state_dir.parent / f".omen-acpi-stock-recovery.old.{os.getpid()}"
    require_absent(old_payload, old_state)
    payload_stage = Path(tempfile.mkdtemp(prefix=".omen-acpi-stock-recovery.", dir=esp))
    state_stage = Path(tempfile.mkdtemp(prefix=".omen-acpi-stock-recovery.", dir=state_dir.parent))
    os.chmod(payload_stage, 0o700)
    os.chmod(state_stage, 0o700)
    activated_payload = activated_state = False
    try:
        payloads = []
        staged_fingerprints = {}
        validated_fingerprints = {
            item[0]: (item[1], item[2]) for item in source_data["fingerprints"]
        }
        sources = [(kernel, kernel_canonical, "kernel.bin", False), *[
            (item[0], item[1], f"module-{index:03}.bin", True)
            for index, item in enumerate(module_pairs)
        ]]
        for source_path, canonical, name, is_module in sources:
            target = payload_stage / name
            expected = validated_fingerprints[canonical]
            digest = copy_stable(source_path, target, expected)
            if is_module:
                inspect_source_initramfs(target, managed_initramfs_hashes())
            staged = stable_fingerprint(target)
            if staged[1] != expected[1]:
                raise Failure(f"staged payload differs from validated source: {name}")
            staged_fingerprints[name] = staged
            payloads.append({"name": name, "sha256": digest, "size": staged[0][2]})

        final_source = validate_normal_source(text, esp)
        if (final_source["normalized"] != source_data["normalized"]
                or final_source["fingerprints"] != source_data["fingerprints"]):
            raise Failure("normal source changed after snapshot payloads were copied")
        normalized = {"protocol": "linux", "kernel_path": kernel_canonical,
                      "module_paths": [item[1] for item in module_pairs], "cmdline": command}
        data = {"schema": SCHEMA, "toolkit_version": VERSION,
                "created_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
                "machine": {"product": product, "board": board, "bios": bios},
                "dsdt": {"revision": probe_state.get("DSDT_REVISION"), "sha256": probe_state.get("DSDT_SHA256")},
                "source_entry": source["title"], "kernel_version": os.uname().release,
                "normalized_entry": normalized, "original_kernel_path": kernel_canonical,
                "original_module_paths": [item[1] for item in module_pairs], "command_line": command,
                "payload_root": "boot():/omen-acpi-stock-recovery", "payloads": payloads,
                "stock_boot_verified": True}
        canonical_json = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
        data["snapshot_id"] = hashlib.sha256(canonical_json).hexdigest()
        manifest = state_stage / "manifest.json"
        manifest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(manifest, 0o600)
        fsync_file(manifest)
        fsync_dir(payload_stage)
        fsync_dir(state_stage)
        manifest_fingerprint = stable_fingerprint(manifest)

        if file_identity(config, text.encode("utf-8")) != (
                config_before.st_dev, config_before.st_ino, config_before.st_size,
                config_before.st_mtime_ns, config_before.st_ctime_ns,
                stat.S_IMODE(config_before.st_mode)):
            raise Failure("Limine configuration changed during snapshot preparation")
        if {item.name for item in payload_stage.iterdir()} != set(staged_fingerprints):
            raise Failure("staged recovery payload contains unexpected files")
        for name, expected in staged_fingerprints.items():
            if stable_fingerprint(payload_stage / name) != expected:
                raise Failure(f"staged recovery payload changed before activation: {name}")
        if {item.name for item in state_stage.iterdir()} != {"manifest.json"} \
                or stable_fingerprint(manifest) != manifest_fingerprint:
            raise Failure("staged recovery manifest changed before activation")
        directory_identity(payload_stage)
        directory_identity(state_stage)
        require_absent(old_payload, old_state)
        require_same_owned_snapshot(esp, initial_snapshot)

        if initial_snapshot is not None:
            rename_noreplace(payload, old_payload)
        rename_noreplace(payload_stage, payload)
        activated_payload = True
        fsync_dir(esp)
        if os.environ.get("OMEN_ACPI_TEST_FAIL_AFTER_PAYLOAD") == "1":
            raise Failure("simulated interruption after payload activation")
        if initial_snapshot is not None:
            rename_noreplace(state_dir, old_state)
        rename_noreplace(state_stage, state_dir)
        activated_state = True
        fsync_dir(state_dir.parent)
        load_owned_snapshot_record(esp)
        # The new pair is committed here. Cleanup is non-essential and must
        # never roll it back after either old component has been deleted.
        activated_payload = activated_state = False
        cleanup_failures = []
        for old, point in ((old_payload, "prepare-old-payload"),
                           (old_state, "prepare-old-state")):
            if path_present(old):
                try:
                    cleanup_tree(old, point)
                except OSError as error:
                    cleanup_failures.append(f"{old}: {error}")
        for failure in cleanup_failures:
            print(f"WARNING: committed snapshot preserved; old backup cleanup failed: {failure}", file=sys.stderr)
        print(f"Stock recovery snapshot prepared from {source['title']!r}.")
    except Exception:
        if activated_state and path_present(state_dir): shutil.rmtree(state_dir)
        if path_present(old_state) and not path_present(state_dir):
            rename_noreplace(old_state, state_dir)
        if activated_payload and path_present(payload): shutil.rmtree(payload)
        if path_present(old_payload) and not path_present(payload):
            rename_noreplace(old_payload, payload)
        raise
    finally:
        if path_present(payload_stage): shutil.rmtree(payload_stage)
        if path_present(state_stage): shutil.rmtree(state_stage)


def owned_block(data: dict) -> str:
    marker = data["snapshot_id"]
    command = data["command_line"]
    command = (command + " " if command else "") + f"omen_acpi.stock_recovery={marker}"
    lines = [BEGIN, f"/{ENTRY}", "    protocol: linux",
             "    kernel_path: boot():/omen-acpi-stock-recovery/kernel.bin"]
    for index in range(len(data["original_module_paths"])):
        lines.append(f"    module_path: boot():/omen-acpi-stock-recovery/module-{index:03}.bin")
    lines.extend((f"    cmdline: {command}", f"    comment: owned-snapshot={marker}", END))
    return "\n".join(lines)


def recover() -> None:
    read_machine()
    esp = resolve_esp_path()
    config = esp / "limine.conf"
    original_bytes = config.read_bytes()
    before_identity = file_identity(config, original_bytes)
    text = original_bytes.decode("utf-8", errors="strict")
    normal = normal_entry(text, required=False)
    if normal is not None:
        source_data = validate_normal_source(text, esp)
        print(f"NORMAL\t{source_data['entry']['title']}")
        return
    initial_snapshot = load_trusted_snapshot_record(esp)
    data = initial_snapshot[0]
    parsed = parse_limine_entries(text)
    reserved = [item for item in parsed if item["title"] == ENTRY]
    if len(reserved) > 1:
        raise Failure("multiple reserved recovery entries exist")
    block = owned_block(data)
    marker_count = text.count(BEGIN) + text.count(END)
    if reserved or marker_count:
        if marker_count != 2 or text.count(block) != 1:
            raise Failure("reserved recovery entry is modified or not owned by this snapshot")
        print(f"READY\t{ENTRY}")
        return
    new_text = text.rstrip("\n") + "\n\n" + block + "\n"
    installed_bytes = new_text.encode("utf-8")
    stage = config.with_name(f".{config.name}.omen-recovery.{os.getpid()}")
    backup = config.with_name(f".{config.name}.omen-recovery-backup.{os.getpid()}")
    require_absent(stage, backup)
    config_replaced = False
    stage_identity = backup_identity = None
    try:
        stage_identity = write_exclusive(stage, installed_bytes, before_identity[-1])
        if file_identity(config, original_bytes) != before_identity:
            raise Failure("Limine configuration changed during recovery")
        backup_identity = write_exclusive(backup, original_bytes, before_identity[-1])
        if file_identity(config, original_bytes) != before_identity:
            raise Failure("Limine configuration changed during recovery backup")
        confirmed_snapshot = load_trusted_snapshot_record(esp)
        if confirmed_snapshot[0]["snapshot_id"] != data["snapshot_id"] \
                or confirmed_snapshot[1] != initial_snapshot[1]:
            raise Failure("trusted recovery snapshot changed before configuration commit")
        if file_identity(stage, installed_bytes) != stage_identity:
            raise Failure("recovery configuration staging changed before commit")
        # This is deliberately the final operation before replace: no snapshot
        # hashing or other long-running check may follow it.
        if file_identity(config, original_bytes) != before_identity:
            raise Failure("Limine configuration changed after snapshot verification")
        os.replace(stage, config)
        config_replaced = True
        fsync_dir(config.parent)
        stage_identity = None
        installed_identity = file_identity(config, installed_bytes)
        committed_snapshot = load_trusted_snapshot_record(esp)
        if committed_snapshot[0]["snapshot_id"] != data["snapshot_id"] \
                or committed_snapshot[1] != initial_snapshot[1]:
            raise Failure("trusted recovery snapshot changed after configuration replacement")
        if file_identity(config, installed_bytes) != installed_identity:
            raise Failure("Limine configuration changed after snapshot commit verification")
        if os.environ.get("OMEN_ACPI_TEST_FAIL_REGENERATE") == "1":
            raise Failure("simulated Limine regeneration failure")
        verify = config.read_bytes()
        if verify != installed_bytes or verify.decode("utf-8", errors="strict").count(block) != 1:
            raise Failure("post-write recovery entry verification failed")
        try:
            cleanup_owned_file(backup, backup_identity)
            backup_identity = None
        except (Failure, OSError) as error:
            print(f"WARNING: recovery committed; configuration backup cleanup failed: {error}",
                  file=sys.stderr)
        print(f"CREATED\t{ENTRY}")
    except Exception:
        if config_replaced and path_present(backup) and backup_identity is not None:
            restore_config_if_unchanged(
                config, backup, installed_bytes, original_bytes, backup_identity
            )
            backup_identity = None if not path_present(backup) else backup_identity
        raise
    finally:
        for temporary, identity in ((stage, stage_identity), (backup, backup_identity)):
            try:
                cleanup_owned_file(temporary, identity)
            except (Failure, OSError) as error:
                print(f"WARNING: foreign or changed transaction file preserved: {error}",
                      file=sys.stderr)


def active() -> None:
    state = probe_boot_state()
    if state.get("STATE") != "stock" or state.get("CLEAN") != "1" or state.get("DSDT_REVISION") != STOCK_REVISION:
        raise Failure("stock recovery marker cannot override a non-stock DSDT classification")
    data = load_trusted_snapshot()
    cmdline = rooted("/proc/cmdline").read_text(encoding="utf-8").split()
    markers = [item.split("=", 1)[1] for item in cmdline if item.startswith("omen_acpi.stock_recovery=")]
    if markers != [data["snapshot_id"]]:
        raise Failure("stock recovery boot marker is absent, duplicated or stale")
    print("STOCK RECOVERY ACTIVE")


def remove() -> None:
    # Removal remains available after a BIOS change, but ownership remains exact.
    esp = resolve_esp_path()
    config = esp / "limine.conf"
    original_bytes = config.read_bytes()
    before_identity = file_identity(config, original_bytes)
    text = original_bytes.decode("utf-8", errors="strict")
    try:
        source_data = validate_normal_source(text, esp)
    except Failure as error:
        raise Failure(
            "recovery removal requires one valid normal linux-cachyos entry; "
            "restore a verifiable stock entry before removing the snapshot"
        ) from error
    initial_snapshot = existing_owned_snapshot_record(esp, require_current_machine=False)
    if initial_snapshot is None:
        raise Failure("managed recovery snapshot is missing")
    data = initial_snapshot[0]
    block = owned_block(data)
    reserved = [item for item in parse_limine_entries(text) if item["title"] == ENTRY]
    if len(reserved) > 1 or text.count(BEGIN) != text.count(END) or text.count(BEGIN) > 1:
        raise Failure("reserved recovery ownership markers are ambiguous")
    if reserved and (BEGIN not in text or text.count(block) != 1):
        raise Failure("reserved recovery entry is foreign or modified")
    if BEGIN in text and (len(reserved) != 1 or text.count(block) != 1):
        raise Failure("reserved recovery entry was modified")
    if not reserved and (BEGIN in text or END in text or
                         "boot():/omen-acpi-stock-recovery" in text):
        raise Failure("foreign recovery ownership marker or payload reference exists")
    new_text = text.replace("\n\n" + block + "\n", "\n").replace(block + "\n", "")
    installed_bytes = new_text.encode("utf-8")
    stage = config.with_name(f".{config.name}.omen-remove.{os.getpid()}")
    backup = config.with_name(f".{config.name}.omen-remove-backup.{os.getpid()}")
    payload, _ = resolve_limine_path(data["payload_root"], esp)
    detached_payload = payload.with_name(f".{payload.name}.removed.{os.getpid()}")
    detached_state = recovery_state_path().with_name(f".{recovery_state_path().name}.removed.{os.getpid()}")
    require_absent(stage, backup, detached_payload, detached_state)
    config_replaced = False
    removal_committed = False
    stage_identity = backup_identity = None
    try:
        stage_identity = write_exclusive(stage, installed_bytes, before_identity[-1])
        backup_identity = write_exclusive(backup, original_bytes, before_identity[-1])
        if file_identity(config, original_bytes) != before_identity:
            raise Failure("Limine configuration changed during removal backup")
        # Full source -> full snapshot -> full source prevents either expensive
        # verifier from opening a new unchecked boundary before the replace.
        require_same_normal_source(text, esp, source_data)
        require_same_owned_snapshot(esp, initial_snapshot, require_current_machine=False)
        require_same_normal_source(text, esp, source_data)
        if file_identity(stage, installed_bytes) != stage_identity:
            raise Failure("removal configuration staging changed before commit")
        require_normal_source_identities(esp, source_data)
        # Final immediate configuration check: no long-running work follows.
        if file_identity(config, original_bytes) != before_identity:
            raise Failure("Limine configuration changed before removal commit")
        os.replace(stage, config)
        config_replaced = True
        fsync_dir(config.parent)
        stage_identity = None
        installed_identity = file_identity(config, installed_bytes)
        require_same_owned_snapshot(esp, initial_snapshot, require_current_machine=False)
        require_same_normal_source(new_text, esp, source_data)
        if file_identity(config, installed_bytes) != installed_identity:
            raise Failure("Limine configuration changed after removal verification")
        require_normal_source_identities(esp, source_data)
        if file_identity(config, installed_bytes) != installed_identity:
            raise Failure("Limine configuration changed before recovery detach")
        require_absent(detached_payload, detached_state)
        rename_noreplace(payload, detached_payload)
        rename_noreplace(recovery_state_path(), detached_state)
        detached_snapshot = load_owned_snapshot_record(
            esp, state_path=detached_state, payload_path=detached_payload,
            require_current_machine=False
        )
        if detached_snapshot[0]["snapshot_id"] != data["snapshot_id"] \
                or detached_snapshot[1][0] != initial_snapshot[1][0] \
                or detached_snapshot[1][3] != initial_snapshot[1][3]:
            raise Failure("detached recovery snapshot differs from verified ownership")
        if path_present(payload) or path_present(recovery_state_path()):
            raise Failure("managed recovery state did not detach completely")
        require_same_normal_source(new_text, esp, source_data)
        if file_identity(config, installed_bytes) != installed_identity:
            raise Failure("Limine configuration changed during removal commit")
        require_normal_source_identities(esp, source_data)
        if file_identity(config, installed_bytes) != installed_identity:
            raise Failure("Limine configuration changed at final removal boundary")
        verified = config.read_bytes()
        if verified != installed_bytes:
            raise Failure("Limine configuration bytes changed during removal commit")
        verified_text = verified.decode("utf-8", errors="strict")
        if (ENTRY in verified_text or BEGIN in verified_text or END in verified_text or
                "boot():/omen-acpi-stock-recovery" in verified_text):
            raise Failure("post-removal verification failed")
        # Detach plus verified config is the commit point. Leftovers are safe,
        # hidden and explicitly reported if non-essential cleanup fails.
        removal_committed = True
        cleanup_failures = []
        cleanup_safe = True
        try:
            cleanup_snapshot = load_owned_snapshot_record(
                esp, state_path=detached_state, payload_path=detached_payload,
                require_current_machine=False
            )
            if cleanup_snapshot[0]["snapshot_id"] != data["snapshot_id"] \
                    or cleanup_snapshot[1][3] != detached_snapshot[1][3]:
                raise Failure("detached recovery state changed before cleanup")
        except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
            cleanup_safe = False
            cleanup_failures.append(
                f"{detached_payload} and {detached_state}: cleanup skipped: {error}"
            )
        if cleanup_safe:
            for old, point in ((detached_payload, "remove-detached-payload"),
                               (detached_state, "remove-detached-state")):
                try:
                    cleanup_tree(old, point)
                except OSError as error:
                    cleanup_failures.append(f"{old}: {error}")
        try:
            cleanup_owned_file(backup, backup_identity, "remove-config-backup")
            backup_identity = None
        except (Failure, OSError) as error:
            cleanup_failures.append(f"{backup}: {error}")
        for failure in cleanup_failures:
            print(f"WARNING: removal committed; detached cleanup failed: {failure}", file=sys.stderr)
        print("Stock recovery entry, payloads and state removed.")
    except Exception:
        if path_present(detached_state) and not path_present(recovery_state_path()):
            rename_noreplace(detached_state, recovery_state_path())
        if path_present(detached_payload) and not path_present(payload):
            rename_noreplace(detached_payload, payload)
        if config_replaced and path_present(backup) and backup_identity is not None:
            restore_config_if_unchanged(
                config, backup, installed_bytes, original_bytes, backup_identity
            )
            backup_identity = None if not path_present(backup) else backup_identity
        raise
    finally:
        try:
            cleanup_owned_file(stage, stage_identity)
        except (Failure, OSError) as error:
            print(f"WARNING: foreign or changed transaction file preserved: {error}",
                  file=sys.stderr)
        if not removal_committed:
            try:
                cleanup_owned_file(backup, backup_identity)
            except (Failure, OSError) as error:
                print(f"WARNING: foreign or changed transaction file preserved: {error}",
                      file=sys.stderr)


def status() -> None:
    def emit(key: str, value: object) -> None:
        print(f"{key}\t{str(value).replace(chr(9), ' ').replace(chr(10), ' ')}")

    boot = "unavailable"
    revision = "unavailable"
    detection = "the current ACPI state could not be verified"
    try:
        current = probe_boot_state()
        boot = current.get("STATE", "unavailable")
        if current.get("CLEAN") != "1" and boot not in ("unknown", "unavailable"):
            boot = "modified"
        revision = current.get("DSDT_REVISION", "unavailable")
        detection = current.get("REASON", current.get("DETECTION", "no detection reason was reported"))
    except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        detection = str(error)

    snapshot_state = normal_state = recovery_state = "unavailable"
    data = None
    normal = None
    normal_sources = []
    normal_kernel_ids: list[str] = []
    text = ""
    try:
        read_machine()
        esp = resolve_esp_path()
        text = (esp / "limine.conf").read_text(encoding="utf-8", errors="strict")
        try:
            candidates = normal_entries(text)
        except Failure:
            normal_state = "ambiguous"
        else:
            if not candidates:
                normal_state = "missing"
            else:
                try:
                    normal_sources = [
                        validate_normal_source(text, esp, candidate)
                        for candidate in candidates
                    ]
                    normal = normal_sources[0]["entry"]
                    normal_kernel_ids = [
                        item["entry"].get("kernel_id", item["entry"]["title"].lower())
                        for item in normal_sources
                    ]
                    normal_state = "available"
                except Failure:
                    normal = None
                    normal_sources = []
                    normal_state = "unusable"

        payload = esp / "omen-acpi-stock-recovery"
        state_present = path_present(recovery_state_path())
        payload_present = path_present(payload)
        if not state_present and not payload_present:
            snapshot_state = "missing"
        elif state_present != payload_present:
            snapshot_state = "modified"
        else:
            try:
                data = load_owned_snapshot(esp)
                if data["toolkit_version"] in TRUSTED_SNAPSHOT_VERSIONS:
                    snapshot_state = "valid"
                else:
                    snapshot_state = "refresh-required"
                if normal_sources and snapshot_state == "valid":
                    stored_normalized = (
                        data["source_entry"],
                        data["original_kernel_path"],
                        tuple(data["original_module_paths"]),
                        data["command_line"],
                    )
                    source_data = next(
                        (item for item in normal_sources if item["normalized"] == stored_normalized),
                        None,
                    )
                    if source_data is None:
                        snapshot_state = "stale"
                    else:
                        sources = [source_data["kernel"], *[item[0] for item in source_data["modules"]]]
                        stored = data["payloads"]
                        if len(sources) != len(stored) or any(sha256_file(source) != item["sha256"] for source, item in zip(sources, stored)):
                            snapshot_state = "stale"
            except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError):
                snapshot_state = "modified"

        reserved = [item for item in parse_limine_entries(text) if item["title"] == ENTRY]
        if not reserved and BEGIN not in text and END not in text:
            recovery_state = "missing"
        elif len(reserved) != 1 or text.count(BEGIN) != 1 or text.count(END) != 1 or data is None:
            recovery_state = "modified"
        else:
            if text.count(owned_block(data)) != 1:
                recovery_state = "modified"
            elif data["toolkit_version"] in TRUSTED_SNAPSHOT_VERSIONS:
                recovery_state = "available"
            else:
                recovery_state = "legacy-untrusted"
    except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError):
        pass

    if boot == "stock" and snapshot_state == "missing" and normal_state == "available":
        recommendation = "Choose option 1 to create the preventive snapshot."
    elif boot == "stock" and snapshot_state == "missing":
        recommendation = (
            "Restore and verify one usable normal stock entry before creating a snapshot; "
            "no automatic change is safe."
        )
    elif boot == "stock" and snapshot_state == "valid":
        recommendation = "A valid snapshot is available; refreshing it is optional."
    elif boot == "stock" and snapshot_state == "refresh-required" and normal_state == "available":
        recommendation = "Refresh the untrusted 2.1.10 snapshot now from this clean stock boot."
    elif snapshot_state == "refresh-required" and normal_state == "available":
        recommendation = "Boot the normal stock entry, then refresh the untrusted 2.1.10 snapshot."
    elif snapshot_state == "refresh-required" and normal_state != "available":
        recommendation = "Automatic recovery is blocked; restore a normal stock entry with external recovery media."
    elif boot in ("s5", "combined") and normal_state == "available":
        recommendation = "Choose option 2 to reboot using the normal stock entry."
    elif boot in ("s5", "combined") and normal_state == "missing" and snapshot_state in ("valid", "stale"):
        recommendation = "Choose option 2 to create the managed recovery entry after confirmation."
    elif normal_state == "missing" and snapshot_state == "missing":
        recommendation = "Automatic recovery is impossible; use external manual recovery media."
    elif boot in ("modified", "unknown", "unavailable") or normal_state in ("ambiguous", "unavailable") or snapshot_state == "modified":
        recommendation = "No automatic change is safe while recovery state is ambiguous or unverifiable."
    else:
        recommendation = "Review the detailed status before choosing an action."

    emit("BOOT", boot)
    emit("DSDT_REVISION", revision)
    emit("DETECTION", detection)
    emit("SNAPSHOT", snapshot_state)
    emit("SNAPSHOT_CREATED", data["created_utc"] if data else "unavailable")
    emit("SNAPSHOT_VERSION", data["toolkit_version"] if data else "unavailable")
    emit("KERNEL", f"{data['kernel_version']} ({data['original_kernel_path']})" if data else "unavailable")
    emit("MODULES", len(data["original_module_paths"]) if data else 0)
    if data and snapshot_state == "refresh-required":
        hashes = "integrity-checked-only; stock provenance untrusted"
    elif data and snapshot_state in ("valid", "stale"):
        hashes = "verified stock snapshot"
    else:
        hashes = "unavailable"
    emit("HASHES", hashes)
    emit("NORMAL_ENTRY", normal_state)
    emit("NORMAL_KERNELS", ",".join(normal_kernel_ids) if normal_kernel_ids else "none")
    emit("RECOVERY_ENTRY", recovery_state)
    emit("RECOMMENDATION", recommendation)


# Command-line entry point

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "recover", "remove", "status", "active"))
    arguments = parser.parse_args()
    if not os.environ.get("OMEN_ACPI_TEST_ROOT") and os.geteuid() != 0:
        raise Failure("stock recovery manager must run as root")
    if arguments.action == "status":
        status()
        return 0
    if arguments.action == "prepare":
        require_transform_machine()
    lock = acquire_lock()
    try:
        if arguments.action == "prepare":
            prepare()
        elif arguments.action == "recover":
            recover()
        elif arguments.action == "remove":
            remove()
        elif arguments.action == "active":
            active()
    finally:
        lock.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
