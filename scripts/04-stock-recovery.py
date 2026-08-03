#!/usr/bin/env python3
"""Fail-closed preventive stock-boot recovery manager.

All mutable paths can be redirected below OMEN_ACPI_TEST_ROOT.  Production
invocations deliberately have no option for selecting arbitrary paths.
"""

from __future__ import annotations

import argparse
import datetime as dt
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

VERSION = "2.1.10"
SCHEMA = 1
ENTRY = "zz-omen-acpi-stock-recovery"
BEGIN = "# BEGIN OMEN-ACPI OWNED STOCK RECOVERY v1"
END = "# END OMEN-ACPI OWNED STOCK RECOVERY v1"
EXPECTED = ("OMEN Gaming Laptop 16-ap0xxx", "8E35", "F.13")
STOCK_REVISION = "0x01072009"
VARIANT_MARKERS = ("omen_acpi.variant=",)


class Failure(RuntimeError):
    pass


def rooted(path: str) -> Path:
    root = os.environ.get("OMEN_ACPI_TEST_ROOT")
    if root:
        return Path(root) / path.lstrip("/")
    return Path(path)


STATE = lambda: rooted("/var/lib/omen-acpi-stock-recovery")
LOCK = lambda: rooted("/run/omen-acpi-fix/manager.lock")


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def regular(path: Path, *, owner: int | None = None, links: int = 1) -> os.stat_result:
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


def secure_dir(path: Path, *, mode: int = 0o700) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise Failure(f"cannot inspect directory {path}: {error}") from error
    expected_owner = os.geteuid() if os.environ.get("OMEN_ACPI_TEST_ROOT") else 0
    if not stat.S_ISDIR(info.st_mode) or path.is_symlink() or info.st_uid != expected_owner:
        raise Failure(f"unsafe directory: {path}")
    if stat.S_IMODE(info.st_mode) != mode:
        raise Failure(f"unsafe mode for {path}: {stat.S_IMODE(info.st_mode):04o}")


def fsync_file(path: Path) -> None:
    with path.open("rb", buffering=0) as stream:
        os.fsync(stream.fileno())


def fsync_dir(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def acquire_lock():
    path = LOCK()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink():
        raise Failure("unsafe lock directory")
    os.chmod(path.parent, 0o700)
    stream = path.open("a+")
    fcntl.flock(stream, fcntl.LOCK_EX)
    return stream


def machine() -> tuple[str, str, str]:
    values = []
    for name in ("product_name", "board_name", "bios_version"):
        path = rooted(f"/sys/class/dmi/id/{name}")
        values.append(path.read_text(encoding="utf-8").strip())
    result = tuple(values)
    if result != EXPECTED:
        raise Failure(f"unsupported machine: product={result[0]!r}, board={result[1]!r}, BIOS={result[2]!r}")
    return result  # type: ignore[return-value]


def esp_path() -> Path:
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
    secure_dir(esp, mode=stat.S_IMODE(esp.stat().st_mode))
    config = esp / "limine.conf"
    regular(config)
    return esp


ENTRY_RE = re.compile(r"^\s*(/+)(\+?)([^/].*)$")
OPTION_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$")


def entries(text: str) -> list[dict]:
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
        for line in lines[item["start"] + 1:item["end"]]:
            match = OPTION_RE.match(line)
            if not match:
                continue
            key, value = match.group(1).lower(), match.group(2)
            if key == "module_path":
                modules.append(value)
            elif key != "comment":
                if key in options:
                    item["duplicate"] = key
                options[key] = value
        item.update(options=options, modules=modules, block="\n".join(lines[item["start"]:item["end"]]))
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


def normal_entry(text: str, *, required: bool = True) -> dict | None:
    found = entries(text)
    named = [item for item in found if item["title"].lower() == "linux-cachyos"]
    if named:
        level = min(item["level"] for item in named)
        candidates = [item for item in named if item["level"] == level]
    else:
        candidates = []
        for item in found:
            searchable = f"{item['title']}\n{item['block']}".lower()
            if "linux-cachyos" in searchable and not any(word in searchable for word in ("fallback", "snapshot", "omen-acpi")):
                candidates.append(item)
    valid = []
    for item in candidates:
        try:
            boot_fields(item)
            valid.append(item)
        except Failure:
            if item["title"].lower() == "linux-cachyos":
                raise
    if len(valid) > 1:
        raise Failure("normal CachyOS entry selection is ambiguous")
    if not valid:
        if required:
            raise Failure("normal CachyOS entry is missing")
        return None
    return valid[0]


def limine_local(value: str, esp: Path) -> tuple[Path, str]:
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


def probe() -> dict[str, str]:
    script = Path(__file__).with_name("00-probe-boot.sh")
    result = subprocess.run([str(script), "--env"], text=True, capture_output=True, env=os.environ)
    if result.returncode:
        raise Failure("the current ACPI state could not be verified")
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return values


def copy_stable(source: Path, target: Path) -> str:
    before = regular(source)
    with source.open("rb", buffering=0) as incoming, target.open("xb", buffering=0) as outgoing:
        shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    after = regular(source)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise Failure(f"source changed during copy: {source}")
    if sha(source) != sha(target):
        raise Failure(f"copy verification failed: {source}")
    return sha(target)


def snapshot() -> dict:
    state = STATE()
    secure_dir(state)
    manifest_path = state / "manifest.json"
    if {item.name for item in state.iterdir()} != {"manifest.json"}:
        raise Failure("recovery state contains unexpected files")
    regular(manifest_path, owner=os.geteuid() if os.environ.get("OMEN_ACPI_TEST_ROOT") else 0)
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise Failure(f"invalid recovery metadata: {error}") from error
    required = {"schema", "toolkit_version", "created_utc", "machine", "dsdt", "source_entry",
                "kernel_version", "normalized_entry", "original_kernel_path", "original_module_paths",
                "command_line", "payload_root", "payloads", "stock_boot_verified", "snapshot_id"}
    if (set(data) != required or data["schema"] != SCHEMA
            or data["toolkit_version"] != VERSION or data["stock_boot_verified"] is not True):
        raise Failure("recovery manifest schema or provenance is invalid")
    if tuple(data["machine"][key] for key in ("product", "board", "bios")) != EXPECTED:
        raise Failure("recovery snapshot belongs to a different machine or BIOS")
    payload_root, canonical = limine_local(data["payload_root"], esp_path())
    if canonical != data["payload_root"] or payload_root.name != "omen-acpi-stock-recovery":
        raise Failure("invalid recovery payload root")
    secure_dir(payload_root)
    expected_names = {item["name"] for item in data["payloads"]}
    actual_names = {item.name for item in payload_root.iterdir()}
    if actual_names != expected_names:
        raise Failure("recovery payload directory is incomplete or contains foreign files")
    for item in data["payloads"]:
        if not re.fullmatch(r"(?:kernel|module-[0-9]{3})\.bin", item["name"]):
            raise Failure("invalid deterministic payload name")
        path = payload_root / item["name"]
        regular(path)
        if path.stat().st_size != item["size"] or sha(path) != item["sha256"]:
            raise Failure(f"recovery payload was modified: {item['name']}")
    canonical_json = json.dumps({key: value for key, value in data.items() if key != "snapshot_id"}, sort_keys=True, separators=(",", ":")).encode()
    if hashlib.sha256(canonical_json).hexdigest() != data["snapshot_id"]:
        raise Failure("recovery metadata was modified")
    return data


def prepare() -> None:
    product, board, bios = machine()
    probe_state = probe()
    if probe_state.get("STATE") != "stock" or probe_state.get("CLEAN") != "1":
        raise Failure(f"snapshot preparation requires a clean verified stock boot; current state is {probe_state.get('STATE', 'unavailable')}")
    esp = esp_path()
    config = esp / "limine.conf"
    config_before = regular(config)
    text = config.read_text(encoding="utf-8", errors="strict")
    source = normal_entry(text)
    assert source is not None
    kernel_value, command, modules = boot_fields(source)
    if any(marker in command for marker in VARIANT_MARKERS) or "omen_acpi.stock_recovery=" in command:
        raise Failure("normal entry contains an OMEN ACPI marker")
    kernel, kernel_canonical = limine_local(kernel_value, esp)
    module_pairs = [limine_local(item, esp) for item in modules]
    forbidden = ("omen-acpi-s5", "omen-acpi-combined", "DSDT.aml")
    for local, canonical in [(kernel, kernel_canonical), *module_pairs]:
        if any(token.lower() in canonical.lower() for token in forbidden):
            raise Failure(f"variant or ACPI-override payload rejected: {canonical}")
        regular(local)
    payload = esp / "omen-acpi-stock-recovery"
    if payload.exists() or payload.is_symlink():
        secure_dir(payload)
        snapshot()  # prove ownership before replacement
    payload_stage = Path(tempfile.mkdtemp(prefix=".omen-acpi-stock-recovery.", dir=esp))
    state_dir = STATE()
    state_dir.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_stage = Path(tempfile.mkdtemp(prefix=".omen-acpi-stock-recovery.", dir=state_dir.parent))
    os.chmod(payload_stage, 0o700); os.chmod(state_stage, 0o700)
    old_payload = esp / f".omen-acpi-stock-recovery.old.{os.getpid()}"
    old_state = state_dir.parent / f".omen-acpi-stock-recovery.old.{os.getpid()}"
    activated_payload = activated_state = False
    try:
        payloads = []
        sources = [(kernel, "kernel.bin"), *[(item[0], f"module-{index:03}.bin") for index, item in enumerate(module_pairs)]]
        for source_path, name in sources:
            digest = copy_stable(source_path, payload_stage / name)
            payloads.append({"name": name, "sha256": digest, "size": (payload_stage / name).stat().st_size})
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
        os.chmod(manifest, 0o600); fsync_file(manifest); fsync_dir(payload_stage); fsync_dir(state_stage)
        if regular(config).st_mtime_ns != config_before.st_mtime_ns or sha(config) != hashlib.sha256(text.encode()).hexdigest():
            raise Failure("Limine configuration changed during snapshot preparation")
        if payload.exists(): payload.rename(old_payload)
        payload_stage.rename(payload); activated_payload = True; fsync_dir(esp)
        if os.environ.get("OMEN_ACPI_TEST_FAIL_AFTER_PAYLOAD") == "1":
            raise Failure("simulated interruption after payload activation")
        if state_dir.exists(): state_dir.rename(old_state)
        state_stage.rename(state_dir); activated_state = True; fsync_dir(state_dir.parent)
        snapshot()
        if old_payload.exists(): shutil.rmtree(old_payload)
        if old_state.exists(): shutil.rmtree(old_state)
        print(f"Stock recovery snapshot prepared from {source['title']!r}.")
    except Exception:
        if activated_state and state_dir.exists(): shutil.rmtree(state_dir)
        if old_state.exists(): old_state.rename(state_dir)
        if activated_payload and payload.exists(): shutil.rmtree(payload)
        if old_payload.exists(): old_payload.rename(payload)
        raise
    finally:
        if payload_stage.exists(): shutil.rmtree(payload_stage)
        if state_stage.exists(): shutil.rmtree(state_stage)


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
    machine(); esp = esp_path(); config = esp / "limine.conf"; before = regular(config)
    text = config.read_text(encoding="utf-8", errors="strict")
    normal = normal_entry(text, required=False)
    if normal is not None:
        print(f"NORMAL\t{normal['title']}")
        return
    data = snapshot()
    parsed = entries(text)
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
    stage = config.with_name(f".{config.name}.omen-recovery.{os.getpid()}")
    backup = config.with_name(f".{config.name}.omen-recovery-backup.{os.getpid()}")
    try:
        stage.write_text(new_text, encoding="utf-8"); os.chmod(stage, stat.S_IMODE(before.st_mode)); fsync_file(stage)
        if regular(config).st_mtime_ns != before.st_mtime_ns or sha(config) != hashlib.sha256(text.encode()).hexdigest():
            raise Failure("Limine configuration changed during recovery")
        shutil.copy2(config, backup); fsync_file(backup)
        os.replace(stage, config); fsync_dir(config.parent)
        if os.environ.get("OMEN_ACPI_TEST_FAIL_REGENERATE") == "1":
            raise Failure("simulated Limine regeneration failure")
        verify = config.read_text(encoding="utf-8", errors="strict")
        if verify.count(block) != 1:
            raise Failure("post-write recovery entry verification failed")
        backup.unlink(); print(f"CREATED\t{ENTRY}")
    except Exception:
        if backup.exists(): os.replace(backup, config); fsync_dir(config.parent)
        raise
    finally:
        if stage.exists(): stage.unlink()


def active() -> None:
    state = probe()
    if state.get("STATE") != "stock" or state.get("CLEAN") != "1" or state.get("DSDT_REVISION") != STOCK_REVISION:
        raise Failure("stock recovery marker cannot override a non-stock DSDT classification")
    data = snapshot()
    cmdline = rooted("/proc/cmdline").read_text(encoding="utf-8").split()
    markers = [item.split("=", 1)[1] for item in cmdline if item.startswith("omen_acpi.stock_recovery=")]
    if markers != [data["snapshot_id"]]:
        raise Failure("stock recovery boot marker is absent, duplicated or stale")
    print("STOCK RECOVERY ACTIVE")


def remove() -> None:
    machine(); esp = esp_path(); config = esp / "limine.conf"; text = config.read_text(encoding="utf-8", errors="strict")
    data = snapshot(); block = owned_block(data)
    normal = normal_entry(text, required=False)
    variants = any(item["title"] in ("zz-omen-acpi-s5-test", "zz-omen-acpi-combined-test") for item in entries(text))
    if normal is None and variants:
        raise Failure("recovery removal blocked: it is the only remaining stock boot path while experimental variants exist")
    if text.count(BEGIN) != text.count(END) or text.count(BEGIN) > 1:
        raise Failure("reserved recovery ownership markers are ambiguous")
    if BEGIN in text and text.count(block) != 1:
        raise Failure("reserved recovery entry was modified")
    new_text = text.replace("\n\n" + block + "\n", "\n").replace(block + "\n", "")
    stage = config.with_name(f".{config.name}.omen-remove.{os.getpid()}")
    backup = config.with_name(f".{config.name}.omen-remove-backup.{os.getpid()}")
    payload, _ = limine_local(data["payload_root"], esp)
    detached_payload = payload.with_name(f".{payload.name}.removed.{os.getpid()}")
    detached_state = STATE().with_name(f".{STATE().name}.removed.{os.getpid()}")
    try:
        stage.write_text(new_text, encoding="utf-8"); os.chmod(stage, stat.S_IMODE(config.stat().st_mode)); fsync_file(stage)
        shutil.copy2(config, backup); fsync_file(backup); os.replace(stage, config); fsync_dir(config.parent)
        payload.rename(detached_payload); STATE().rename(detached_state)
        if BEGIN in config.read_text(encoding="utf-8"):
            raise Failure("post-removal verification failed")
        shutil.rmtree(detached_payload); shutil.rmtree(detached_state); backup.unlink()
        print("Stock recovery entry, payloads and state removed.")
    except Exception:
        if detached_state.exists() and not STATE().exists(): detached_state.rename(STATE())
        if detached_payload.exists() and not payload.exists(): detached_payload.rename(payload)
        if backup.exists(): os.replace(backup, config); fsync_dir(config.parent)
        raise
    finally:
        if stage.exists(): stage.unlink()


def status() -> None:
    def emit(key: str, value: object) -> None:
        print(f"{key}\t{str(value).replace(chr(9), ' ').replace(chr(10), ' ')}")

    boot = "unavailable"
    revision = "unavailable"
    detection = "the current ACPI state could not be verified"
    try:
        current = probe()
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
    text = ""
    try:
        machine()
        esp = esp_path()
        text = (esp / "limine.conf").read_text(encoding="utf-8", errors="strict")
        try:
            normal = normal_entry(text, required=False)
            normal_state = "available" if normal is not None else "missing"
        except Failure:
            normal_state = "ambiguous"

        if not STATE().exists() and not STATE().is_symlink():
            snapshot_state = "missing"
        else:
            try:
                data = snapshot()
                snapshot_state = "valid"
                if normal is not None:
                    kernel_value, _command, modules = boot_fields(normal)
                    sources = [limine_local(kernel_value, esp)[0], *[limine_local(item, esp)[0] for item in modules]]
                    stored = data["payloads"]
                    if len(sources) != len(stored) or any(sha(source) != item["sha256"] for source, item in zip(sources, stored)):
                        snapshot_state = "stale"
            except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError):
                snapshot_state = "modified"

        reserved = [item for item in entries(text) if item["title"] == ENTRY]
        if not reserved and BEGIN not in text and END not in text:
            recovery_state = "missing"
        elif len(reserved) != 1 or text.count(BEGIN) != 1 or text.count(END) != 1 or data is None:
            recovery_state = "modified"
        else:
            recovery_state = "available" if text.count(owned_block(data)) == 1 else "modified"
    except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError):
        pass

    if boot == "stock" and snapshot_state == "missing":
        recommendation = "Choose option 1 to create the preventive snapshot."
    elif boot == "stock" and snapshot_state == "valid":
        recommendation = "A valid snapshot is available; refreshing it is optional."
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
    emit("HASHES", "verified" if data and snapshot_state in ("valid", "stale") else "unavailable")
    emit("NORMAL_ENTRY", normal_state)
    emit("RECOVERY_ENTRY", recovery_state)
    emit("RECOMMENDATION", recommendation)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "recover", "remove", "status", "active"))
    arguments = parser.parse_args()
    if not os.environ.get("OMEN_ACPI_TEST_ROOT") and os.geteuid() != 0:
        raise Failure("stock recovery manager must run as root")
    if arguments.action == "status":
        status()
        return 0
    lock = acquire_lock()
    try:
        globals()[arguments.action]()
    finally:
        lock.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
