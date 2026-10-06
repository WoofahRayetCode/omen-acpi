#!/usr/bin/env python3
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
"""Owned hook transactions and durable automatic-refresh diagnostics.

Callers hold the shared boot/toolkit locks during hook mutations. No firmware
or Limine entries are generated here. Test paths require explicit test mode.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile


VARIANTS = ("s5", "combined", "s5-vfio")
HOOKS = {
    "/etc/pacman.d/hooks/99-omen-acpi-refresh.hook": ("alpm/99-omen-acpi-refresh.hook", 0o644),
    "/etc/boot/hooks/post.d/85-omen-acpi-refresh": ("alpm/85-omen-acpi-refresh", 0o755),
}
LEGACY = "/usr/share/libalpm/hooks/90-omen-acpi-refresh.hook"


class Failure(RuntimeError):
    pass


def rooted(value: str) -> Path:
    prefix = os.environ.get("OMEN_ACPI_TEST_ROOT", "") if os.environ.get("OMEN_ACPI_TESTING") == "1" else ""
    return Path(prefix + value)


def owner() -> int:
    return os.geteuid() if os.environ.get("OMEN_ACPI_TESTING") == "1" else 0


def present(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def secure(path: Path, directory: bool = False) -> os.stat_result:
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or path.is_symlink() or info.st_uid != owner()
            or info.st_mode & 0o022 or (not directory and info.st_nlink != 1)):
        raise Failure(f"unsafe {'directory' if directory else 'file'}: {path}")
    return info


def parents(path: Path, create: bool = False) -> None:
    # Test roots may be under /tmp; production checks all ancestors.
    stop = rooted("/")
    chain = []
    cursor = path.parent
    while cursor != stop:
        chain.append(cursor)
        if cursor == cursor.parent:
            raise Failure(f"path outside maintenance root: {path}")
        cursor = cursor.parent
    secure(stop, True)
    for directory in reversed(chain):
        if not present(directory):
            if not create:
                raise Failure(f"missing directory: {directory}")
            directory.mkdir(mode=0o755)
        info = directory.lstat()
        if directory in (rooted("/tmp"), rooted("/var/tmp")) and info.st_mode & stat.S_ISVTX:
            if not stat.S_ISDIR(info.st_mode) or directory.is_symlink() or info.st_uid != owner():
                raise Failure(f"unsafe temporary parent: {directory}")
        else:
            secure(directory, True)


def atomic(path: Path, content: bytes, mode: int) -> None:
    parents(path)
    if present(path):
        secure(path)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_optional(path: Path) -> bytes | None:
    # Never follow a symlinked parent even if the final file is absent.
    cursor = path.parent
    while not present(cursor):
        cursor = cursor.parent
    parents(cursor / "placeholder")
    secure(cursor, True)
    if not present(path):
        return None
    parents(path)
    secure(path)
    return path.read_bytes()


def encoded(content: bytes | None) -> str | None:
    return base64.b64encode(content).decode("ascii") if content is not None else None


def decoded(content: str | None) -> bytes | None:
    return base64.b64decode(content, validate=True) if content is not None else None


def prepare(source: Path, previous: Path, transaction: Path, remove: bool = False) -> None:
    secure(source, True)
    secure(transaction, True)
    records = []
    for name, (relative, mode) in HOOKS.items():
        target = rooted(name)
        before = read_optional(target)
        new_source = source / relative
        parents(new_source)
        secure(new_source)
        new = new_source.read_bytes()
        prior = read_optional(previous / relative)
        if before is not None and before not in (new, prior):
            raise Failure(f"foreign or modified maintenance hook: {target}")
        records.append({"path": name, "before": encoded(before),
                        "after": encoded(None if remove else new),
                        "mode": mode, "before_mode": stat.S_IMODE(target.stat().st_mode) if before is not None else mode})
    legacy = rooted(LEGACY)
    before = read_optional(legacy)
    if before is not None:
        old = read_optional(previous / "alpm/90-omen-acpi-refresh.hook")
        if old is None or before != old:
            raise Failure(f"foreign or modified legacy maintenance hook: {legacy}")
        records.append({"path": LEGACY, "before": encoded(before), "after": None,
                        "mode": 0o644, "before_mode": stat.S_IMODE(legacy.stat().st_mode)})
    data = {"schema": 1, "records": records, "created_directories": []}
    atomic(transaction / "hooks.json", (json.dumps(data, indent=2) + "\n").encode(), 0o600)


def load_transaction(transaction: Path) -> dict:
    secure(transaction, True)
    path = transaction / "hooks.json"
    secure(path)
    data = json.loads(path.read_text())
    if data["schema"] != 1 or len({record["path"] for record in data["records"]}) != len(data["records"]):
        raise Failure("invalid hook transaction")
    for record in data["records"]:
        if record["path"] not in (*HOOKS, LEGACY):
            raise Failure("unexpected hook transaction path")
    return data


def apply(transaction: Path, rollback: bool = False) -> None:
    data = load_transaction(transaction)
    records = list(reversed(data["records"])) if rollback else data["records"]
    for index, record in enumerate(records):
        target = rooted(record["path"])
        before, after = decoded(record["before"]), decoded(record["after"])
        expected, desired = (after, before) if rollback else (before, after)
        current = read_optional(target)
        if current != expected:
            if rollback and current == desired:
                continue  # This step was never applied (or already restored).
            raise Failure(f"hook changed during {'rollback' if rollback else 'transaction'}: {target}")
        if desired is None:
            if current is not None:
                target.unlink()
                fsync_directory(target.parent)
        else:
            if not rollback:
                missing = []
                cursor = target.parent
                while not present(cursor):
                    missing.append(str(cursor))
                    cursor = cursor.parent
                data["created_directories"].extend(reversed(missing))
                atomic(transaction / "hooks.json", (json.dumps(data, indent=2) + "\n").encode(), 0o600)
            parents(target, create=True)
            mode = record["before_mode"] if rollback else record["mode"]
            if current != desired or stat.S_IMODE(target.stat().st_mode) != mode:
                atomic(target, desired, mode)
        if not rollback and os.environ.get("OMEN_ACPI_TESTING") == "1" and os.environ.get("OMEN_ACPI_TEST_FAIL_HOOK") == str(index):
            raise Failure("injected hook transaction failure")
    if rollback:
        allowed = {str(parent) for name in HOOKS for parent in rooted(name).parents if str(parent) != str(rooted('/'))}
        for name in reversed(data["created_directories"]):
            if name not in allowed:
                raise Failure("unexpected rollback directory")
            directory = Path(name)
            if present(directory):
                secure(directory, True)
                try:
                    directory.rmdir()
                except OSError:
                    pass  # Preserve directories now used by other software.


def repair(source: Path) -> None:
    transaction = Path(tempfile.mkdtemp(prefix="omen-acpi-hooks.", dir=rooted("/var/tmp")))
    preserve = False
    try:
        prepare(source, source, transaction)
        try:
            apply(transaction)
        except Exception:
            try:
                apply(transaction, rollback=True)
            except Exception as error:
                preserve = True
                raise Failure(f"hook repair rollback failed; transaction retained at {transaction}: {error}") from error
            raise
    finally:
        if not preserve:
            secure(transaction, True)
            shutil.rmtree(transaction)


def health_path(variant: str) -> Path:
    if variant not in VARIANTS:
        raise Failure("unknown variant")
    return rooted(f"/var/lib/omen-acpi-{variant}-test/auto-refresh.json")


def load_health(path: Path) -> dict | None:
    if not present(path):
        return None
    parents(path)
    secure(path)
    data = json.loads(path.read_text())
    if (set(data) != {"schema", "variant", "attempted_utc", "caller", "exit_code"}
            or data["schema"] != 1 or data["variant"] not in VARIANTS
            or type(data["exit_code"]) is not int or not 0 <= data["exit_code"] <= 255
            or not isinstance(data["caller"], str) or not isinstance(data["attempted_utc"], str)):
        raise Failure(f"invalid automatic-refresh record: {path}")
    if health_path(data["variant"]) != path:
        raise Failure(f"automatic-refresh record has the wrong variant: {path}")
    return data


def record(variant: str, code: int, caller: str) -> None:
    path = health_path(variant)
    parents(path)
    state = secure(path.parent, True)
    load_health(path)  # Never overwrite unrecognized diagnostic state.
    data = {"schema": 1, "variant": variant,
            "attempted_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "caller": caller.replace("\r", " ").replace("\n", " ")[:256], "exit_code": code}
    current = secure(path.parent, True)
    if (state.st_dev, state.st_ino) != (current.st_dev, current.st_ino):
        raise Failure("managed state changed during maintenance recording")
    atomic(path, (json.dumps(data, indent=2) + "\n").encode(), 0o600)


def status(source: Path) -> int:
    failed = False
    for name, (relative, mode) in HOOKS.items():
        try:
            source_file = source / relative
            secure(source_file)
            target = rooted(name)
            content = read_optional(target)
            state = "missing" if content is None else "current" if content == source_file.read_bytes() and stat.S_IMODE(target.stat().st_mode) == mode else "modified"
        except (Failure, OSError):
            state = "unsafe"
        print(f"HOOK\t{name}\t{state}")
        failed |= state != "current"
    for variant in VARIANTS:
        path = health_path(variant)
        if not present(path.parent):
            continue
        try:
            parents(path)
            secure(path.parent, True)
            data = load_health(path)
            if data is None:
                print(f"AUTO\t{variant}\tnot-run")
            else:
                state = "current" if data["exit_code"] == 0 else "failed"
                failed |= state == "failed"
                print(f"AUTO\t{variant}\t{state}\t{data['attempted_utc']}\texit={data['exit_code']}\t{data['caller']}")
        except (Failure, OSError, ValueError, TypeError, KeyError):
            print(f"AUTO\t{variant}\tunsafe")
            failed = True
    return 3 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "apply", "rollback", "repair", "status", "record"))
    parser.add_argument("--source", type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--transaction", type=Path)
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--variant", choices=VARIANTS)
    parser.add_argument("--code", type=int, choices=range(256))
    parser.add_argument("--caller", default="alpm")
    args = parser.parse_args()
    if os.geteuid() != owner():
        raise Failure("maintenance manager must run as root")
    if args.action == "prepare":
        if args.source is None or args.previous is None or args.transaction is None:
            parser.error("prepare requires --source, --previous and --transaction")
        prepare(args.source, args.previous, args.transaction, args.remove)
    elif args.action in ("apply", "rollback"):
        if args.transaction is None:
            parser.error("apply/rollback require --transaction")
        apply(args.transaction, args.action == "rollback")
    elif args.action in ("repair", "status"):
        if args.source is None:
            parser.error("repair/status require --source")
        if args.action == "status":
            return status(args.source)
        repair(args.source)
    else:
        if args.variant is None or args.code is None:
            parser.error("record requires --variant and --code")
        record(args.variant, args.code, args.caller)
    return 0


if __name__ == "__main__":
    import sys
    try:
        raise SystemExit(main())
    except (Failure, OSError, ValueError, TypeError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
