#!/usr/bin/env python3
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reconcile OMEN ACPI entries with the installed CachyOS kernels."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile


SUPPORTED = ("linux-cachyos", "linux-cachyos-lts")
FALLBACKS = tuple(f"{name}-fallback" for name in SUPPORTED)
ENTRY_RE = re.compile(r"^\s*(/+)(\+?)([^/].*)$")
OPTION_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$")
HASH_RE = re.compile(r"^(.*?)(?:#([0-9A-Fa-f]{128}))?$")
SCHEMA = 1


class Failure(RuntimeError):
    pass


# Filesystem safety

def regular(path: Path) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError as error:
        raise Failure(f"cannot inspect regular file {path}: {error}") from error
    expected_owner = os.geteuid() if os.environ.get("OMEN_ACPI_TESTING") == "1" else 0
    if (
        not stat.S_ISREG(info.st_mode)
        or path.is_symlink()
        or info.st_uid != expected_owner
        or info.st_nlink != 1
        or info.st_mode & 0o022
    ):
        raise Failure(f"unsafe regular file: {path}")
    return info


def secure_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise Failure(f"cannot inspect directory {path}: {error}") from error
    expected_owner = os.geteuid() if os.environ.get("OMEN_ACPI_TESTING") == "1" else 0
    if (
        not stat.S_ISDIR(info.st_mode)
        or path.is_symlink()
        or info.st_uid != expected_owner
        or info.st_mode & 0o022
    ):
        raise Failure(f"unsafe directory: {path}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def blake2(path: Path) -> str:
    digest = hashlib.blake2b()
    with path.open("rb", buffering=0) as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


# Limine parsing and stock-source validation

def parse_entries(text: str) -> list[dict]:
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
        found.append(
            {
                "start": index,
                "level": level,
                "parent": stack[-1] if stack else None,
                "title": match.group(3).strip(),
            }
        )
        stack.append(len(found) - 1)
    for index, item in enumerate(found):
        item["end"] = found[index + 1]["start"] if index + 1 < len(found) else len(lines)
        options: dict[str, str] = {}
        modules: list[str] = []
        comments: list[str] = []
        duplicates: list[str] = []
        for line in lines[item["start"] + 1 : item["end"]]:
            match = OPTION_RE.match(line)
            if not match:
                continue
            key, value = match.group(1).lower(), match.group(2)
            if key == "module_path":
                modules.append(value)
            elif key == "comment":
                comments.append(value)
            elif key in options:
                duplicates.append(key)
            else:
                options[key] = value
        item.update(options=options, modules=modules, comments=comments, duplicates=duplicates)
    return found


def boot_fields(item: dict) -> tuple[str, str, list[str]]:
    options = item["options"]
    kernels = [key for key in ("kernel_path", "path") if key in options]
    commands = [key for key in ("cmdline", "kernel_cmdline") if key in options]
    if (
        item["duplicates"]
        or options.get("protocol", "").lower() != "linux"
        or len(kernels) != 1
        or len(commands) > 1
        or not item["modules"]
    ):
        raise Failure(f"malformed Limine entry: {item['title']}")
    command = options[commands[0]] if commands else ""
    command = re.sub(r"(?<!\S)(?:initrd|BOOT_IMAGE)=[^\s]+", "", command)
    command = re.sub(r"\s+", " ", command).strip()
    return options[kernels[0]], command, item["modules"]


def is_historical_entry(entries: list[dict], item: dict) -> bool:
    parent = item["parent"]
    while parent is not None:
        ancestor = entries[parent]
        if "snapshot" in ancestor["title"].lower():
            return True
        parent = ancestor["parent"]
    return False


def active_entries_named(entries: list[dict], name: str) -> list[dict]:
    matches = [
        item
        for item in entries
        if (
            item["title"].lower() == name
            or f"kernel-id={name}" in [value.lower() for value in item["comments"]]
        )
        and not is_historical_entry(entries, item)
    ]
    if not matches:
        return []
    level = min(item["level"] for item in matches)
    return [item for item in matches if item["level"] == level]


def supported_entries(text: str) -> tuple[dict[str, dict], dict[str, dict]]:
    parsed = parse_entries(text)
    primary: dict[str, dict] = {}
    fallback: dict[str, dict] = {}
    namespace: tuple[int, int | None] | None = None
    for name in (*SUPPORTED, *FALLBACKS):
        matches = active_entries_named(parsed, name)
        if len(matches) > 1:
            raise Failure(f"active Limine entry {name!r} is duplicated")
        if not matches:
            continue
        item = matches[0]
        boot_fields(item)
        identifiers = [
            value.split("=", 1)[1].lower()
            for value in item["comments"]
            if value.lower().startswith("kernel-id=")
        ]
        if identifiers and identifiers != [name]:
            raise Failure(f"Limine entry {name!r} has a conflicting kernel-id marker")
        current_namespace = (item["level"], item["parent"])
        if namespace is None:
            namespace = current_namespace
        elif namespace != current_namespace:
            raise Failure("supported CachyOS entries do not share one active Limine namespace")
        (fallback if name in FALLBACKS else primary)[name] = item
    if not primary:
        raise Failure("no supported primary CachyOS kernel entry was found")
    return primary, fallback


def resolve_limine(value: str, esp: Path) -> tuple[Path, str]:
    value = value.strip()
    if value.startswith("$"):
        value = value[1:]
    match = HASH_RE.fullmatch(value)
    if not match:
        raise Failure(f"invalid Limine path: {value}")
    path_value, expected_hash = match.groups()
    resource = re.fullmatch(r"boot\(\):/([^\x00\r\n]+)", path_value)
    if not resource:
        raise Failure(f"unsupported Limine path: {value}")
    pure = PurePosixPath(resource.group(1))
    if not pure.parts or any(part in ("", ".", "..") for part in pure.parts):
        raise Failure(f"noncanonical Limine path: {value}")
    local = esp.joinpath(*pure.parts)
    cursor = esp
    for part in pure.parts[:-1]:
        cursor /= part
        if (cursor.exists() or cursor.is_symlink()) and cursor.is_symlink():
            raise Failure(f"symlinked Limine path component: {value}")
    parent = local.parent.resolve()
    if parent != esp and esp not in parent.parents:
        raise Failure(f"Limine path escapes the ESP: {value}")
    regular(local)
    if expected_hash and blake2(local) != expected_hash.lower():
        raise Failure(f"Limine BLAKE2 hash does not match: {value}")
    canonical = f"boot():/{pure.as_posix()}"
    if expected_hash:
        canonical += f"#{expected_hash.lower()}"
    return local, canonical


def inspect_initramfs(path: Path) -> list[str]:
    command = os.environ.get("OMEN_ACPI_TEST_LSINITCPIO", "lsinitcpio")
    try:
        result = subprocess.run(
            [command, "-l", str(path)], text=True, capture_output=True, check=False
        )
    except OSError as error:
        raise Failure(f"cannot inspect initramfs {path}: {error}") from error
    if result.returncode:
        raise Failure(f"lsinitcpio could not inspect stock initramfs: {path}")
    members = [line.strip().lstrip("./") for line in result.stdout.splitlines()]
    if any(
        item == "kernel/firmware/acpi" or item.startswith("kernel/firmware/acpi/")
        for item in members
    ):
        raise Failure(f"stock initramfs already contains an ACPI override: {path}")
    return sorted(
        {
            PurePosixPath(item).name
            for item in members
            if re.search(r"(?:^|/)nvidia[^/]*\.ko(?:\.[a-z0-9]+)?$", item, re.I)
        }
    )


def validated_sources(text: str, esp: Path) -> tuple[dict[str, dict], dict[str, dict]]:
    primary, fallback = supported_entries(text)
    for group in (primary, fallback):
        for kernel_id, item in group.items():
            kernel, command, modules = boot_fields(item)
            if "omen_acpi." in command:
                raise Failure(f"stock entry {kernel_id!r} contains an OMEN ACPI marker")
            kernel_local, kernel_path = resolve_limine(kernel, esp)
            module_data = []
            nvidia: set[str] = set()
            for value in modules:
                local, canonical = resolve_limine(value, esp)
                module_nvidia = inspect_initramfs(local)
                nvidia.update(module_nvidia)
                module_data.append((local, canonical, module_nvidia))
            item.update(
                kernel_id=kernel_id,
                kernel_local=kernel_local,
                kernel_path=kernel_path,
                command=command,
                module_data=module_data,
                nvidia=sorted(nvidia),
            )
    return primary, fallback


# Managed entry format and ownership

CURRENT_TITLES = {
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


def variant_names(variant: str) -> dict[str, str]:
    if variant not in CURRENT_TITLES:
        raise Failure(f"unsupported variant: {variant}")
    return dict(CURRENT_TITLES[variant])


def legacy_variant_names(variant: str) -> dict[str, str]:
    if variant not in LEGACY_TITLES:
        raise Failure(f"unsupported variant: {variant}")
    return dict(LEGACY_TITLES[variant])


def reserved_titles(variant: str) -> set[str]:
    return set(variant_names(variant).values()) | set(legacy_variant_names(variant).values())


def entry_comment(variant: str) -> str:
    if variant == "s5":
        return "Experimental S5 GPU power-off override. Stock CachyOS entry unchanged."
    if variant == "combined":
        return "Experimental S5 override plus WQBZ buffer bounds. Stock CachyOS entry unchanged."
    raise Failure(f"unsupported variant: {variant}")


def owner_marker(variant: str, kernel_id: str) -> str:
    return f"omen-acpi-owned=v1 variant={variant} kernel={kernel_id}"


def entry_record(variant: str, source: dict, early_path: str) -> dict:
    kernel_id = source["kernel_id"]
    title = variant_names(variant)[kernel_id]
    command = source["command"]
    marker = f"omen_acpi.variant={variant}"
    command = f"{command} {marker}".strip()
    return {
        "title": title,
        "source_title": source["title"],
        "kernel_id": kernel_id,
        "level": source["level"],
        "kernel_path": source["kernel_path"],
        "module_paths": [early_path, *[item[1] for item in source["module_data"]]],
        "cmdline": command,
        "owner": owner_marker(variant, kernel_id),
    }


def render_entry(record: dict) -> list[str]:
    indent = " " * 4
    owner = re.fullmatch(
        r"omen-acpi-owned=v1 variant=(s5|combined) kernel=(linux-cachyos(?:-lts)?)",
        record["owner"],
    )
    if owner is None:
        raise Failure("owned Limine record is missing a valid ownership marker")
    lines = [
        "/" * record["level"] + record["title"],
        f"{indent}comment: {entry_comment(owner.group(1))}",
        f"{indent}comment: {record['owner']}",
        f"{indent}protocol: linux",
        f"{indent}kernel_path: {record['kernel_path']}",
    ]
    lines.extend(f"{indent}module_path: {value}" for value in record["module_paths"])
    lines.append(f"{indent}cmdline: {record['cmdline']}")
    return lines


def normalized_owned(item: dict) -> dict:
    kernel, command, modules = boot_fields(item)
    owners = [value for value in item["comments"] if value.startswith("omen-acpi-owned=")]
    if len(owners) != 1:
        raise Failure(f"reserved entry {item['title']!r} has no unique ownership marker")
    match = re.fullmatch(r"omen-acpi-owned=v1 variant=(s5|combined) kernel=(linux-cachyos(?:-lts)?)", owners[0])
    if not match:
        raise Failure(f"reserved entry {item['title']!r} has an invalid ownership marker")
    return {
        "title": item["title"],
        "source_title": "",
        "kernel_id": match.group(2),
        "level": item["level"],
        "kernel_path": kernel,
        "module_paths": modules,
        "cmdline": command,
        "owner": owners[0],
    }


def load_manifest(state: Path, variant: str) -> dict | None:
    path = state / "kernel-entries.json"
    if not path.exists() and not path.is_symlink():
        return None
    regular(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise Failure(f"invalid managed kernel-entry state: {error}") from error
    if (
        set(data) != {"schema", "variant", "early_path", "early_sha256", "entries"}
        or data["schema"] != SCHEMA
        or data["variant"] != variant
        or not isinstance(data["entries"], dict)
        or not data["entries"]
        or set(data["entries"]) - set(SUPPORTED)
        or not re.fullmatch(r"[0-9a-f]{64}", data["early_sha256"])
    ):
        raise Failure("managed kernel-entry state has an invalid schema")
    return data


def limine_globals(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if ENTRY_RE.match(line):
            break
        match = OPTION_RE.match(line)
        if match is None:
            continue
        key = match.group(1).lower()
        if key in values:
            raise Failure(f"duplicate Limine global option: {key}")
        values[key] = match.group(2)
    return values


def supported_stock_fingerprint(text: str) -> dict[str, tuple]:
    primary, fallback = supported_entries(text)
    blocks: dict[str, tuple] = {}
    for mapping in (primary, fallback):
        for kernel_id, item in mapping.items():
            kernel, command, modules = boot_fields(item)
            blocks[kernel_id] = (
                item["title"],
                item["level"],
                item["parent"],
                kernel,
                command,
                tuple(modules),
                tuple(item["comments"]),
            )
    return blocks


def assert_stock_preserved(original: str, updated: str) -> None:
    if limine_globals(original) != limine_globals(updated):
        raise Failure("Limine global options were modified")
    if supported_stock_fingerprint(original) != supported_stock_fingerprint(updated):
        raise Failure("stock CachyOS Limine entries were modified")


def verify_owned_entries(text: str, manifest: dict | None, variant: str, namespace: tuple[int, int | None]) -> list[dict]:
    entries = parse_entries(text)
    names = reserved_titles(variant)
    candidates = [
        item
        for item in entries
        if item["title"] in names and (item["level"], item["parent"]) == namespace
    ]
    foreign = [
        item
        for item in entries
        if item["title"] in names
        and item not in candidates
        and not is_historical_entry(entries, item)
    ]
    if foreign:
        raise Failure("a reserved OMEN ACPI entry exists outside the active CachyOS namespace")
    expected = manifest["entries"] if manifest else {}
    if len(candidates) != len(expected):
        raise Failure("reserved OMEN ACPI entries do not match managed state")
    actual: dict[str, dict] = {}
    for item in candidates:
        record = normalized_owned(item)
        kernel_id = record["kernel_id"]
        if kernel_id in actual:
            raise Failure("a reserved OMEN ACPI entry is duplicated")
        actual[kernel_id] = record
    for kernel_id, record in expected.items():
        comparable = dict(record)
        comparable["source_title"] = ""
        if actual.get(kernel_id) != comparable:
            raise Failure(f"managed {variant} entry for {kernel_id} was modified")
    return candidates


def write_atomic(path: Path, content: bytes, mode: int) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def rebuild_config(text: str, owned: list[dict], records: dict[str, dict]) -> str:
    lines = text.splitlines()
    trailing = text.endswith("\n")
    remove: set[int] = set()
    for item in owned:
        remove.update(range(item["start"], item["end"]))
    if owned:
        preceding = min(item["start"] for item in owned) - 1
        if preceding >= 0 and not lines[preceding]:
            remove.add(preceding)
    remaining = [line for index, line in enumerate(lines) if index not in remove]
    reparsed_primary, _ = supported_entries("\n".join(remaining) + ("\n" if trailing else ""))
    insertion = max(item["end"] for item in reparsed_primary.values())
    blocks: list[str] = []
    for kernel_id in SUPPORTED:
        if kernel_id in records:
            if blocks:
                blocks.append("")
            blocks.extend(render_entry(records[kernel_id]))
    remaining[insertion:insertion] = ["", *blocks] if blocks else []
    result = "\n".join(remaining)
    if trailing:
        result += "\n"
    return result


def load_state_early(state: Path) -> tuple[bytes, str]:
    secure_directory(state)
    early = state / "early.cpio"
    checksum = state / "early.sha256"
    regular(early)
    regular(checksum)
    expected = checksum.read_text(encoding="ascii").strip()
    content = early.read_bytes()
    if (
        not re.fullmatch(r"[0-9a-f]{64}", expected)
        or hashlib.sha256(content).hexdigest() != expected
    ):
        raise Failure("managed early initramfs is missing or modified")
    return content, expected


def managed_payload_directory(esp: Path, variant: str, *, create: bool = True) -> Path:
    root = esp / "omen-acpi"
    if root.exists() or root.is_symlink():
        secure_directory(root)
    elif not create:
        raise Failure(f"managed payload directory is missing: {root}")
    else:
        root.mkdir(mode=0o700)
    target = root / variant
    if target.exists() or target.is_symlink():
        secure_directory(target)
    elif not create:
        raise Failure(f"managed payload directory is missing: {target}")
    else:
        target.mkdir(mode=0o700)
    return target


def configuration_unchanged(path: Path, original: str, info: os.stat_result) -> bool:
    current = regular(path)
    return (
        (current.st_dev, current.st_ino, current.st_uid, current.st_mode)
        == (info.st_dev, info.st_ino, info.st_uid, info.st_mode)
        and path.read_text(encoding="utf-8", errors="strict") == original
    )


# Reconciliation actions

def sync(esp: Path, state: Path, variant: str) -> None:
    secure_directory(esp)
    config = esp / "limine.conf"
    config_info = regular(config)
    original = config.read_text(encoding="utf-8", errors="strict")
    primary, _fallback = validated_sources(original, esp)
    first = next(iter(primary.values()))
    namespace = (first["level"], first["parent"])
    manifest = load_manifest(state, variant)
    owned = verify_owned_entries(original, manifest, variant, namespace)
    early, early_sha = load_state_early(state)
    target_dir = managed_payload_directory(esp, variant)
    target = target_dir / "early.cpio"
    target_previous: bytes | None = None
    target_mode = 0o600
    if target.exists() or target.is_symlink():
        target_info = regular(target)
        target_previous = target.read_bytes()
        target_mode = stat.S_IMODE(target_info.st_mode)
        allowed = {early_sha}
        if manifest:
            allowed.add(manifest["early_sha256"])
        if sha256(target) not in allowed:
            raise Failure(f"managed ESP early initramfs was modified: {target}")
    write_atomic(target, early, 0o600)
    early_path = f"boot():/omen-acpi/{variant}/early.cpio#{blake2(target)}"
    records = {
        kernel_id: entry_record(variant, source, early_path)
        for kernel_id, source in primary.items()
    }
    updated = rebuild_config(original, owned, records)
    assert_stock_preserved(original, updated)
    data = {
        "schema": SCHEMA,
        "variant": variant,
        "early_path": early_path,
        "early_sha256": early_sha,
        "entries": records,
    }
    manifest_path = state / "kernel-entries.json"
    previous_manifest = manifest_path.read_bytes() if manifest_path.exists() else None
    config_changed = updated != original
    try:
        if not configuration_unchanged(config, original, config_info):
            raise Failure("Limine configuration changed during reconciliation")
        if config_changed:
            write_atomic(config, updated.encode("utf-8"), stat.S_IMODE(config_info.st_mode))
        write_atomic(
            manifest_path,
            (json.dumps(data, indent=2, sort_keys=True) + "\n").encode(),
            0o600,
        )
    except Exception:
        if config_changed and config.read_text(encoding="utf-8", errors="strict") == updated:
            write_atomic(config, original.encode("utf-8"), stat.S_IMODE(config_info.st_mode))
        if previous_manifest is not None:
            write_atomic(manifest_path, previous_manifest, 0o600)
        elif manifest_path.exists() and not manifest_path.is_symlink():
            manifest_path.unlink()
        if target_previous is not None:
            write_atomic(target, target_previous, target_mode)
        elif target.exists() and not target.is_symlink() and sha256(target) == early_sha:
            target.unlink()
            for directory in (target.parent, target.parent.parent):
                try:
                    directory.rmdir()
                except OSError:
                    break
        raise
    print(f"SYNCED\t{variant}\t{','.join(records)}")


def remove(esp: Path, state: Path, variant: str) -> None:
    secure_directory(esp)
    config = esp / "limine.conf"
    info = regular(config)
    original = config.read_text(encoding="utf-8", errors="strict")
    primary, _fallback = supported_entries(original)
    first = next(iter(primary.values()))
    namespace = (first["level"], first["parent"])
    manifest = load_manifest(state, variant)
    if manifest is None:
        raise Failure("managed kernel-entry state is missing")
    owned = verify_owned_entries(original, manifest, variant, namespace)
    lines = original.splitlines()
    trailing = original.endswith("\n")
    remove_lines = {
        index for item in owned for index in range(item["start"], item["end"])
    }
    preceding = min(item["start"] for item in owned) - 1
    if preceding >= 0 and not lines[preceding]:
        remove_lines.add(preceding)
    updated_lines = [line for index, line in enumerate(lines) if index not in remove_lines]
    while len(updated_lines) >= 2 and not updated_lines[-1] and not updated_lines[-2]:
        updated_lines.pop()
    updated = "\n".join(updated_lines) + ("\n" if trailing else "")
    assert_stock_preserved(original, updated)
    target = managed_payload_directory(esp, variant, create=False) / "early.cpio"
    regular(target)
    if sha256(target) != manifest["early_sha256"]:
        raise Failure("managed ESP early initramfs was modified")
    detached = target.with_name(f".early.cpio.removing.{os.getpid()}")
    if detached.exists() or detached.is_symlink():
        raise Failure(f"unexpected removal staging path: {detached}")
    os.replace(target, detached)
    try:
        if not configuration_unchanged(config, original, info):
            raise Failure("Limine configuration changed during removal")
        write_atomic(config, updated.encode("utf-8"), stat.S_IMODE(info.st_mode))
    except Exception:
        os.replace(detached, target)
        raise
    try:
        detached.unlink()
    except OSError as error:
        try:
            if config.read_text(encoding="utf-8", errors="strict") != updated:
                raise Failure("Limine configuration changed after removal commit")
            write_atomic(config, original.encode("utf-8"), stat.S_IMODE(info.st_mode))
            os.replace(detached, target)
        except Exception as rollback_error:
            raise Failure(
                f"payload cleanup failed and removal could not be rolled back: {rollback_error}"
            ) from error
        raise Failure("payload cleanup failed; removal was rolled back") from error
    for directory in (target.parent, target.parent.parent):
        try:
            directory.rmdir()
        except OSError:
            break
    print(f"REMOVED\t{variant}")


def status(esp: Path, state: Path | None, variant: str | None) -> int:
    secure_directory(esp)
    config = esp / "limine.conf"
    regular(config)
    text = config.read_text(encoding="utf-8", errors="strict")
    primary, fallback = validated_sources(text, esp)
    release = os.uname().release
    try:
        running_id = (Path("/usr/lib/modules") / release / "pkgbase").read_text().strip()
    except (OSError, UnicodeError):
        running_id = "unknown"
    if running_id not in SUPPORTED:
        running_id = "unknown"
    print(f"RUNNING\t{release}\t{running_id}")
    for kernel_id in SUPPORTED:
        if kernel_id not in primary:
            continue
        source = primary[kernel_id]
        print(
            "KERNEL\t{}\t{}\t{}\t{}\t{}".format(
                kernel_id,
                source["title"],
                source["kernel_path"],
                len(source["module_data"]),
                ",".join(source["nvidia"]) or "none-detected",
            )
        )
        if f"{kernel_id}-fallback" in fallback:
            print(f"FALLBACK\t{kernel_id}\tpresent")
        for index, module in enumerate(source["module_data"]):
            print(
                f"MODULE\t{kernel_id}\t{index}\t{module[1]}\t"
                f"{','.join(module[2]) or 'none-detected'}"
            )
    if variant is None:
        return 0
    first = next(iter(primary.values()))
    namespace = (first["level"], first["parent"])
    if state is None:
        try:
            verify_owned_entries(text, None, variant, namespace)
        except Failure as error:
            print(f"VARIANT\t{variant}\tconflict\t{error}")
            return 3
        print(f"VARIANT\t{variant}\tabsent")
        return 0
    try:
        manifest = load_manifest(state, variant)
        verify_owned_entries(text, manifest, variant, namespace)
        if manifest is not None:
            _early, state_sha = load_state_early(state)
            target, canonical = resolve_limine(manifest["early_path"], esp)
            expected_target = esp / "omen-acpi" / variant / "early.cpio"
            if (
                canonical != manifest["early_path"]
                or target != expected_target
                or state_sha != manifest["early_sha256"]
                or sha256(target) != state_sha
            ):
                raise Failure("managed early initramfs state does not match the ESP")
    except Failure as error:
        print(f"VARIANT\t{variant}\tconflict\t{error}")
        return 3
    if manifest is None:
        print(f"VARIANT\t{variant}\tabsent")
        return 0
    current_ids = set(primary)
    configured_ids = set(manifest["entries"])
    expected = {
        kernel_id: entry_record(variant, source, manifest["early_path"])
        for kernel_id, source in primary.items()
    }
    state_name = (
        "current"
        if current_ids == configured_ids and expected == manifest["entries"]
        else "stale"
    )
    for kernel_id in SUPPORTED:
        if kernel_id in current_ids or kernel_id in configured_ids:
            configured = kernel_id in configured_ids
            present = kernel_id in current_ids
            print(
                f"ENTRY\t{variant}\t{kernel_id}\t"
                f"{'current' if present and configured else 'missing' if present else 'obsolete'}"
            )
    print(f"VARIANT\t{variant}\t{state_name}")
    return 0 if state_name == "current" else 3


# Command-line entry point

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("list", "sync", "remove", "status"))
    parser.add_argument("--esp", required=True, type=Path)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--variant", choices=("s5", "combined"))
    arguments = parser.parse_args()
    esp = arguments.esp.absolute()
    if arguments.action in ("sync", "remove") and (arguments.state is None or arguments.variant is None):
        parser.error("sync/remove require --state and --variant")
    if arguments.action == "status":
        return status(
            esp,
            arguments.state.absolute() if arguments.state else None,
            arguments.variant,
        )
    if arguments.action == "list":
        return status(esp, None, None)
    state = arguments.state.absolute()
    if arguments.action == "sync":
        sync(esp, state, arguments.variant)
    elif arguments.action == "remove":
        remove(esp, state, arguments.variant)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
