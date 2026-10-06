#!/usr/bin/env python3
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic hook transactions, automatic-refresh and lock regressions."""
from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("maintenance", ROOT / "scripts/07-maintenance.py")
assert SPEC and SPEC.loader
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)


class LifecycleRulesTest(unittest.TestCase):
    """Exercise public variant dispatch with the privileged operations stubbed."""

    def run_cli(self, body: str) -> list[str]:
        bash = "bash" if os.name == "posix" else r"C:\Program Files\Git\bin\bash.exe"
        if os.name != "posix" and not Path(bash).exists():
            self.skipTest("Git Bash is required for portable CLI tests")
        script = r'''
source "$1"
ensure_dependencies() { :; }
ensure_admin() { :; }
machine_supported() { return 0; }
probe_boot() { :; }
refine_installation_formats_cached() { :; }
stock_recovery_status() { :; }
stock_recovery_snapshot_status() { printf missing; }
boot_state_label() { printf fixture; }
refresh_one() { printf 'VISITED:%s\n' "$1"; }
status_one() { printf 'VISITED:%s\n' "$1"; }
remove_one() { printf 'VISITED:%s\n' "$1"; }
build_one() { printf 'VISITED:%s\n' "$1"; }
''' + body
        environment = dict(os.environ, OMEN_ACPI_TESTING="1", OMEN_ACPI_SOURCE_ONLY="1")
        result = subprocess.run([bash, "-c", script, "_", (ROOT / "omen-acpi").as_posix()],
                                text=True, encoding="utf-8", capture_output=True, env=environment, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line.removeprefix("VISITED:") for line in result.stdout.splitlines() if line.startswith("VISITED:")]

    def test_refresh_all_includes_vfio(self):
        self.assertEqual(self.run_cli("refresh_variants all\n"), list(maintenance.VARIANTS))

    def test_refresh_both_keeps_the_original_pair(self):
        self.assertEqual(self.run_cli("refresh_variants both\n"), ["s5", "combined"])

    def test_status_all_includes_vfio(self):
        self.assertEqual(self.run_cli("status_variants all\n"), list(maintenance.VARIANTS))

    def test_remove_all_and_individual_vfio(self):
        self.assertEqual(self.run_cli("remove_variants all\n"), list(maintenance.VARIANTS))
        self.assertEqual(self.run_cli("remove_variants s5-vfio\n"), ["s5-vfio"])

    def test_remove_both_keeps_the_original_pair(self):
        self.assertEqual(self.run_cli("remove_variants both\n"), ["s5", "combined"])

    def test_build_both_does_not_install_vfio(self):
        self.assertEqual(self.run_cli("build_variants both source-fixture.tar.gz\n"), ["s5", "combined"])


@unittest.skipUnless(os.name == "posix", "Linux ownership, flock and fsync semantics required")
class MaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="omen-maintenance-test."))
        self.root = self.work / "root"
        self.root.mkdir(mode=0o700)
        self.env = mock.patch.dict(os.environ, {"OMEN_ACPI_TESTING": "1", "OMEN_ACPI_TEST_ROOT": str(self.root)}, clear=False)
        self.env.start()
        for name in ("run", "var/tmp", "var/lib", "app/alpm", "previous/alpm", "transaction"):
            (self.root / name).mkdir(parents=True, mode=0o700, exist_ok=True)
        self.source = self.root / "app"
        self.previous = self.root / "previous"
        self.transaction = self.root / "transaction"
        for relative, mode in maintenance.HOOKS.values():
            source = ROOT / "packaging" / Path(relative).name
            target = self.source / relative
            shutil.copyfile(source, target)
            target.chmod(mode)
        self.manager = self.root / "manager"
        self.manager.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$2" >> "$OMEN_ACPI_TEST_ROOT/calls"\n[[ "$2" != "${TEST_FAIL_VARIANT:-}" ]]\n')
        self.manager.chmod(0o755)

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.work)

    def prepare(self, remove=False):
        maintenance.prepare(self.source, self.previous, self.transaction, remove)

    def hooks(self):
        return {name: maintenance.read_optional(maintenance.rooted(name)) for name in (*maintenance.HOOKS, maintenance.LEGACY)}

    def install_hooks(self):
        self.prepare()
        maintenance.apply(self.transaction)

    def variants(self):
        for variant in maintenance.VARIANTS:
            state = self.root / f"var/lib/omen-acpi-{variant}-test"
            state.mkdir(mode=0o700)
            (state / "kernel-entries.json").write_text("{}\n")

    def auto(self, extra=None, pass_fds=()):
        environment = dict(os.environ, OMEN_ACPI_MANAGER=str(self.manager))
        environment.update(extra or {})
        return subprocess.run(["bash", str(ROOT / "scripts/06-alpm-refresh.sh")], env=environment,
                              pass_fds=pass_fds, text=True, capture_output=True, timeout=15)

    def test_install_remove_and_rollback(self):
        self.install_hooks()
        installed = self.hooks()
        for name, (_, mode) in maintenance.HOOKS.items():
            self.assertIsNotNone(installed[name])
            self.assertEqual(maintenance.rooted(name).stat().st_mode & 0o777, mode)
        maintenance.apply(self.transaction, rollback=True)
        self.assertTrue(all(value is None for value in self.hooks().values()))
        self.install_hooks()
        maintenance.prepare(self.source, self.source, self.transaction, remove=True)
        maintenance.apply(self.transaction)
        self.assertTrue(all(value is None for value in self.hooks().values()))
        maintenance.apply(self.transaction, rollback=True)
        self.assertEqual(self.hooks(), installed)

    def test_each_injected_hook_failure_rolls_back(self):
        old_source = self.previous / "alpm/90-omen-acpi-refresh.hook"
        old_source.write_bytes(b"previous owned hook\n")
        legacy = maintenance.rooted(maintenance.LEGACY)
        maintenance.parents(legacy, create=True)
        legacy.write_bytes(old_source.read_bytes())
        before = self.hooks()
        for point in ("0", "1", "2"):
            self.prepare()
            with mock.patch.dict(os.environ, OMEN_ACPI_TEST_FAIL_HOOK=point):
                with self.assertRaises(maintenance.Failure):
                    maintenance.apply(self.transaction)
            maintenance.apply(self.transaction, rollback=True)
            self.assertEqual(self.hooks(), before)

    def test_modified_and_foreign_legacy_hooks_are_preserved(self):
        target = maintenance.rooted(next(iter(maintenance.HOOKS)))
        maintenance.parents(target, create=True)
        target.write_bytes(b"foreign local hook")
        with self.assertRaises(maintenance.Failure):
            self.prepare()
        self.assertEqual(target.read_bytes(), b"foreign local hook")
        target.unlink()
        legacy = maintenance.rooted(maintenance.LEGACY)
        maintenance.parents(legacy, create=True)
        legacy.write_bytes(b"foreign legacy hook")
        with self.assertRaises(maintenance.Failure):
            self.prepare()
        self.assertEqual(legacy.read_bytes(), b"foreign legacy hook")

    def test_symlinked_hook_parent_is_rejected(self):
        (self.root / "etc").mkdir()
        (self.root / "foreign").mkdir()
        (self.root / "etc/pacman.d").symlink_to(self.root / "foreign", target_is_directory=True)
        with self.assertRaises(maintenance.Failure):
            self.prepare()
        self.assertEqual(list((self.root / "foreign").iterdir()), [])

    def test_doctor_repairs_missing_owned_hook(self):
        self.install_hooks()
        target = maintenance.rooted("/etc/boot/hooks/post.d/85-omen-acpi-refresh")
        target.unlink()
        maintenance.repair(self.source)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(maintenance.status(self.source), 0)

    def test_all_variants_record_failure_without_failing_update(self):
        self.variants()
        result = self.auto({"TEST_FAIL_VARIANT": "combined", "HOOK_CALLER": "limine-mkinitcpio-install"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "calls").read_text().splitlines(), list(maintenance.VARIANTS))
        for variant in maintenance.VARIANTS:
            data = json.loads(maintenance.health_path(variant).read_text())
            self.assertEqual(data["exit_code"], 1 if variant == "combined" else 0)
            self.assertEqual(data["caller"], "limine-mkinitcpio-install")
        self.assertIn("run omen-acpi refresh combined", result.stderr)

    def test_automatic_lock_contention_is_fail_soft_and_recorded(self):
        import fcntl
        self.variants()
        lock = self.root / "run/lock/boot-partition.lock"
        lock.parent.mkdir(mode=0o700)
        with lock.open("w") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            result = self.auto()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "calls").exists())
        for variant in maintenance.VARIANTS:
            self.assertEqual(json.loads(maintenance.health_path(variant).read_text())["exit_code"], 75)

    def test_limine_inherited_lock_is_reused_and_not_released(self):
        import fcntl
        self.variants()
        lock = self.root / "run/lock/boot-partition.lock"
        lock.parent.mkdir(mode=0o700)
        with lock.open("w") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            os.dup2(stream.fileno(), 200)
            try:
                result = self.auto({"OMEN_ACPI_BOOT_LOCK_FD200_HELD": "1"}, pass_fds=(200,))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.root / "calls").exists(), result.stderr)
                with lock.open("a") as contender:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(200)

    def test_recursive_toolkit_operation_is_skipped(self):
        self.variants()
        result = self.auto({"OMEN_ACPI_INTERNAL_OPERATION": "1"})
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls").exists())
        self.assertTrue(all(not maintenance.health_path(v).exists() for v in maintenance.VARIANTS))

    def test_modified_health_record_is_not_overwritten(self):
        self.variants()
        path = maintenance.health_path("s5")
        path.write_text("{}")
        with self.assertRaises((maintenance.Failure, KeyError)):
            maintenance.record("s5", 0, "alpm")
        self.assertEqual(path.read_text(), "{}")

    def test_bios_change_blocks_refresh(self):
        self.variants()
        fixture = self.root / "scripts"
        fixture.mkdir()
        manager = fixture / "03-manage-limine-entry.sh"
        manager.write_text((ROOT / "scripts/03-manage-limine-entry.sh").read_text().removesuffix('main "$@"\n'))
        shutil.copyfile(ROOT / "scripts/05-kernel-entries.py", fixture / "05-kernel-entries.py")
        (fixture / "05-kernel-entries.py").chmod(0o755)
        script = r'''
source "$1"
require_root() { :; }
select_variant s5
STATE_DIR="$OMEN_ACPI_TEST_ROOT/var/lib/omen-acpi-s5-test"
need_cmd() { :; }
acquire_lock() { :; }
verify_state_identity() { :; }
managed_state_valid() { return 0; }
read_machine() { MACHINE_PRODUCT=fixture; MACHINE_BOARD=fixture; MACHINE_BIOS=F.14; }
state_machine() { printf 'fixture\tfixture\tF.13\n'; }
refresh_action
'''
        result = subprocess.run(["bash", "-c", script, "_", str(manager)],
                                text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different machine or BIOS", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
