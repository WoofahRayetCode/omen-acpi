#!/usr/bin/env python3
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic-only regression tests for preventive stock recovery."""

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("stock_recovery", ROOT / "scripts/04-stock-recovery.py")
assert SPEC and SPEC.loader
recovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recovery)


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="omen-stock-recovery-test."))
        self.root = self.temp / "root"
        self.esp = self.root / "boot"
        self.esp.mkdir(parents=True, mode=0o700)
        (self.root / "run/omen-acpi-fix").mkdir(parents=True, mode=0o700)
        dmi = self.root / "sys/class/dmi/id"
        dmi.mkdir(parents=True)
        for name, value in zip(("product_name", "board_name", "bios_version"), recovery.EXPECTED):
            (dmi / name).write_text(value + "\n")
        (self.esp / "vmlinuz-linux-cachyos").write_bytes(b"stock-kernel\0exact")
        (self.esp / "initramfs-linux-cachyos.img").write_bytes(b"stock-initramfs-one")
        (self.esp / "cpu-ucode.img").write_bytes(b"stock-initramfs-two")
        self.lsinitcpio = self.temp / "lsinitcpio"
        self.lsinitcpio.write_text("#!/bin/sh\nprintf '%s\\n' usr/bin/init\n")
        self.lsinitcpio.chmod(0o755)
        self.original = (
            "timeout: 5\n"
            "default_entry: 2\n"
            "# user comment\n"
            "/Linux-CachyOS\n"
            "    protocol: linux\n"
            "    kernel_path: boot():/vmlinuz-linux-cachyos\n"
            "    module_path: boot():/cpu-ucode.img\n"
            "    module_path: boot():/initramfs-linux-cachyos.img\n"
            "    cmdline: quiet splash\n"
            "/User rescue\n"
            "    protocol: linux\n"
            "    kernel_path: boot():/other\n"
            "    module_path: boot():/other-initrd\n"
        )
        (self.esp / "limine.conf").write_text(self.original)
        self.environment = mock.patch.dict(os.environ, {
            "OMEN_ACPI_TEST_ROOT": str(self.root), "OMEN_ACPI_TEST_ESP": str(self.esp),
            "OMEN_ACPI_TEST_LSINITCPIO": str(self.lsinitcpio)
        }, clear=False)
        self.environment.start()
        self.probe = mock.patch.object(recovery, "probe", return_value={
            "STATE": "stock", "CLEAN": "1", "DSDT_REVISION": recovery.STOCK_REVISION,
            "DSDT_SHA256": "a" * 64,
        })
        self.probe.start()

    def tearDown(self):
        self.probe.stop(); self.environment.stop(); shutil.rmtree(self.temp)

    def prepare(self):
        recovery.prepare()
        return recovery.snapshot()

    def test_prepare_exact_payloads_manifest_and_order(self):
        data = self.prepare()
        payload = self.esp / "omen-acpi-stock-recovery"
        self.assertEqual((payload / "kernel.bin").read_bytes(), b"stock-kernel\0exact")
        self.assertEqual((payload / "module-000.bin").read_bytes(), b"stock-initramfs-two")
        self.assertEqual((payload / "module-001.bin").read_bytes(), b"stock-initramfs-one")
        self.assertEqual(data["original_module_paths"], ["boot():/cpu-ucode.img", "boot():/initramfs-linux-cachyos.img"])
        self.assertTrue(data["stock_boot_verified"])
        self.assertEqual(data["machine"]["bios"], "F.13")
        self.assertEqual(data["dsdt"]["revision"], recovery.STOCK_REVISION)

    def test_prepare_rejects_nonstock_states_and_unsupported_machine(self):
        for state in ("s5", "combined", "unknown", "unavailable"):
            with self.subTest(state=state), mock.patch.object(recovery, "probe", return_value={"STATE": state, "CLEAN": "0"}):
                with self.assertRaises(recovery.Failure): recovery.prepare()
        (self.root / "sys/class/dmi/id/board_name").write_text("WRONG\n")
        with self.assertRaises(recovery.Failure): recovery.prepare()

    def test_missing_and_duplicate_normal_entry_are_rejected(self):
        config = self.esp / "limine.conf"
        config.write_text("timeout: 5\n")
        with self.assertRaises(recovery.Failure): recovery.prepare()
        config.write_text(self.original + self.original[self.original.index("/Linux-CachyOS"):self.original.index("/User rescue")])
        with self.assertRaises(recovery.Failure): recovery.prepare()

    def test_paths_symlinks_variants_and_aliases_are_rejected(self):
        config = self.esp / "limine.conf"
        cases = ("/../vmlinuz", "/etc/passwd", "/omen-acpi-s5.img")
        for value in cases:
            with self.subTest(value=value):
                config.write_text(self.original.replace("boot():/vmlinuz-linux-cachyos", value))
                with self.assertRaises(recovery.Failure): recovery.prepare()
        config.write_text(self.original)
        (self.esp / "vmlinuz-linux-cachyos").unlink()
        (self.esp / "vmlinuz-linux-cachyos").symlink_to("cpu-ucode.img")
        with self.assertRaises(recovery.Failure): recovery.prepare()

    def test_copy_failure_rolls_back_without_partial_state(self):
        with mock.patch.object(recovery, "copy_stable", side_effect=recovery.Failure("injected copy failure")):
            with self.assertRaises(recovery.Failure): recovery.prepare()
        self.assertFalse(recovery.STATE().exists())
        self.assertFalse((self.esp / "omen-acpi-stock-recovery").exists())

    def test_snapshot_tampering_missing_payload_and_unsafe_state_fail(self):
        self.prepare()
        payload = self.esp / "omen-acpi-stock-recovery"
        for name in ("kernel.bin", "module-000.bin"):
            with self.subTest(name=name):
                original = (payload / name).read_bytes(); (payload / name).write_bytes(original + b"tamper")
                with self.assertRaises(recovery.Failure): recovery.snapshot()
                (payload / name).write_bytes(original)
        manifest = recovery.STATE() / "manifest.json"
        original_manifest = manifest.read_text(); manifest.write_text(original_manifest.replace("F.13", "F.99"))
        with self.assertRaises(recovery.Failure): recovery.snapshot()
        manifest.write_text(original_manifest)
        (payload / "module-001.bin").unlink()
        with self.assertRaises(recovery.Failure): recovery.snapshot()

    def test_stale_metadata_and_payload_symlink_are_rejected(self):
        self.prepare(); manifest = recovery.STATE() / "manifest.json"
        data = json.loads(manifest.read_text()); data["toolkit_version"] = "2.1.9"
        manifest.write_text(json.dumps(data))
        with self.assertRaises(recovery.Failure): recovery.snapshot()
        self.setUp_snapshot_again_after_tamper()
        payload = self.esp / "omen-acpi-stock-recovery/module-000.bin"
        payload.unlink(); payload.symlink_to("module-001.bin")
        with self.assertRaises(recovery.Failure): recovery.snapshot()

    def test_valid_2_1_10_snapshot_can_be_verified_and_refreshed(self):
        self.prepare(); manifest = recovery.STATE() / "manifest.json"
        data = json.loads(manifest.read_text()); data["toolkit_version"] = "2.1.10"
        canonical = json.dumps({key: value for key, value in data.items() if key != "snapshot_id"},
                               sort_keys=True, separators=(",", ":")).encode()
        data["snapshot_id"] = recovery.hashlib.sha256(canonical).hexdigest()
        manifest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        self.assertEqual(recovery.snapshot()["toolkit_version"], "2.1.10")
        recovery.prepare()
        self.assertEqual(recovery.snapshot()["toolkit_version"], "2.1.11")

    def setUp_snapshot_again_after_tamper(self):
        shutil.rmtree(recovery.STATE())
        shutil.rmtree(self.esp / "omen-acpi-stock-recovery")
        self.prepare()

    def test_interruption_after_payload_activation_has_complete_rollback(self):
        old = self.prepare(); old_kernel = (self.esp / "omen-acpi-stock-recovery/kernel.bin").read_bytes()
        (self.esp / "vmlinuz-linux-cachyos").write_bytes(b"new-stock-kernel")
        with mock.patch.dict(os.environ, {"OMEN_ACPI_TEST_FAIL_AFTER_PAYLOAD": "1"}):
            with self.assertRaises(recovery.Failure): recovery.prepare()
        self.assertEqual(recovery.snapshot()["snapshot_id"], old["snapshot_id"])
        self.assertEqual((self.esp / "omen-acpi-stock-recovery/kernel.bin").read_bytes(), old_kernel)

    def test_renamed_override_initramfs_is_rejected_and_old_snapshot_survives(self):
        old = self.prepare()
        script = "#!/bin/sh\nprintf '%s\\n' kernel/firmware/acpi/DSDT.aml\n"
        self.lsinitcpio.write_text(script)
        with self.assertRaises(recovery.Failure):
            recovery.prepare()
        self.assertEqual(recovery.snapshot()["snapshot_id"], old["snapshot_id"])

    def test_renamed_managed_payload_hash_is_rejected(self):
        old = self.prepare()
        managed = self.root / "var/lib/omen-acpi-s5-test"
        managed.mkdir(mode=0o700)
        source = self.esp / "initramfs-linux-cachyos.img"
        (managed / "initramfs.img").write_bytes(source.read_bytes())
        (managed / "initramfs.sha256").write_text(recovery.sha(source) + "\n")
        with self.assertRaises(recovery.Failure):
            recovery.prepare()
        self.assertEqual(recovery.snapshot()["snapshot_id"], old["snapshot_id"])

    def test_prepare_cleanup_failure_keeps_new_committed_pair(self):
        for point in ("prepare-old-payload", "prepare-old-state"):
            with self.subTest(point=point):
                self.prepare()
                (self.esp / "vmlinuz-linux-cachyos").write_bytes(f"new-{point}".encode())
                with mock.patch.dict(os.environ, {"OMEN_ACPI_TEST_FAIL_CLEANUP": point}):
                    recovery.prepare()
                self.assertEqual((self.esp / "omen-acpi-stock-recovery/kernel.bin").read_bytes(), f"new-{point}".encode())
                recovery.snapshot()
                for old in (*self.esp.glob(".omen-acpi-stock-recovery.old.*"),
                            *recovery.STATE().parent.glob(".omen-acpi-stock-recovery.old.*")):
                    shutil.rmtree(old)
                shutil.rmtree(recovery.STATE()); shutil.rmtree(self.esp / "omen-acpi-stock-recovery")

    def test_missing_normal_and_missing_snapshot_never_change_limine(self):
        config = self.esp / "limine.conf"
        text = self.original[:self.original.index("/Linux-CachyOS")] + self.original[self.original.index("/User rescue"):]
        config.write_text(text)
        with self.assertRaises(recovery.Failure): recovery.recover()
        self.assertEqual(config.read_text(), text)

    def test_state_symlink_and_mode_are_rejected(self):
        state = recovery.STATE(); state.parent.mkdir(parents=True, exist_ok=True)
        state.symlink_to(self.temp)
        with self.assertRaises(recovery.Failure): recovery.snapshot()
        state.unlink(); state.mkdir(mode=0o755)
        with self.assertRaises(recovery.Failure): recovery.snapshot()

    def test_normal_entry_means_recover_never_changes_config(self):
        before = (self.esp / "limine.conf").read_bytes()
        recovery.recover()
        self.assertEqual((self.esp / "limine.conf").read_bytes(), before)

    def test_missing_normal_creates_owned_idempotent_recovery_only(self):
        data = self.prepare(); config = self.esp / "limine.conf"
        config.write_text(self.original[:self.original.index("/Linux-CachyOS")] + self.original[self.original.index("/User rescue"):])
        preserved = config.read_text()
        recovery.recover(); first = config.read_text(); recovery.recover()
        self.assertEqual(config.read_text(), first)
        self.assertIn(preserved.rstrip(), first)
        self.assertIn("kernel_path: boot():/omen-acpi-stock-recovery/kernel.bin", first)
        self.assertNotIn(data["original_kernel_path"] + "\n    module_path", first[first.index(recovery.BEGIN):])
        self.assertLess(first.index("module-000.bin"), first.index("module-001.bin"))
        self.assertIn("timeout: 5", first); self.assertIn("default_entry: 2", first)

    def test_modified_and_duplicate_reserved_entries_are_blocked(self):
        self.prepare(); config = self.esp / "limine.conf"
        config.write_text(self.original[:self.original.index("/Linux-CachyOS")] + self.original[self.original.index("/User rescue"):])
        recovery.recover(); exact = config.read_text()
        config.write_text(exact.replace("kernel.bin", "evil.bin"))
        with self.assertRaises(recovery.Failure): recovery.recover()
        config.write_text(exact + "\n/zz-omen-acpi-stock-recovery\n protocol: linux\n kernel_path: boot():/x\n module_path: boot():/y\n")
        with self.assertRaises(recovery.Failure): recovery.recover()

    def test_remove_rejects_reserved_title_without_markers(self):
        self.prepare(); config = self.esp / "limine.conf"
        config.write_text(self.original + "\n/zz-omen-acpi-stock-recovery\n protocol: linux\n kernel_path: boot():/x\n module_path: boot():/y\n")
        before = config.read_bytes()
        with self.assertRaises(recovery.Failure): recovery.remove()
        self.assertEqual(config.read_bytes(), before)
        recovery.snapshot()

    def test_remove_rejects_every_ambiguous_reserved_form_without_writes(self):
        data = self.prepare(); config = self.esp / "limine.conf"; block = recovery.owned_block(data)
        cases = {
            "one-begin": self.original + "\n" + recovery.BEGIN + "\n/zz-omen-acpi-stock-recovery\n",
            "one-end": self.original + "\n/zz-omen-acpi-stock-recovery\n" + recovery.END + "\n",
            "duplicate-marker": self.original + "\n" + block + "\n" + recovery.BEGIN + "\n",
            "foreign-entry": self.original + "\n/zz-omen-acpi-stock-recovery\n protocol: linux\n kernel_path: boot():/foreign\n module_path: boot():/foreign\n",
            "modified-owned": self.original + "\n" + block.replace("kernel.bin", "changed.bin") + "\n",
            "duplicate-entry": self.original + "\n" + block + "\n" + block + "\n",
        }
        for name, content in cases.items():
            with self.subTest(name=name):
                config.write_text(content); before = config.read_bytes()
                with self.assertRaises(recovery.Failure): recovery.remove()
                self.assertEqual(config.read_bytes(), before)
                recovery.snapshot()

    def test_recover_detects_change_during_backup(self):
        self.prepare(); config = self.esp / "limine.conf"
        without_normal = self.original[:self.original.index("/Linux-CachyOS")] + self.original[self.original.index("/User rescue"):]
        config.write_text(without_normal)
        original = recovery.file_identity
        calls = 0
        def inject(path, expected=None):
            nonlocal calls
            calls += 1
            if calls == 3:
                config.write_text(without_normal + "# external change\n")
            return original(path, expected)
        with mock.patch.object(recovery, "file_identity", side_effect=inject):
            with self.assertRaises(recovery.Failure): recovery.recover()
        self.assertIn("external change", config.read_text())

    def test_recover_detects_change_after_replace_and_preserves_external_bytes(self):
        self.prepare(); config = self.esp / "limine.conf"
        without_normal = self.original[:self.original.index("/Linux-CachyOS")] + self.original[self.original.index("/User rescue"):]
        config.write_text(without_normal)
        original_replace = recovery.os.replace
        def replace_then_edit(source, target):
            original_replace(source, target)
            if Path(target) == config:
                config.write_bytes(config.read_bytes() + b"# external recover commit change\n")
        with mock.patch.object(recovery.os, "replace", side_effect=replace_then_edit):
            with self.assertRaises(recovery.Failure): recovery.recover()
        self.assertIn("external recover commit change", config.read_text())
        recovery.snapshot()

    def test_remove_detects_change_during_backup(self):
        self.prepare(); config = self.esp / "limine.conf"; original_bytes = config.read_bytes()
        identity = recovery.file_identity; calls = 0
        def inject(path, expected=None):
            nonlocal calls
            calls += 1
            if calls == 2:
                config.write_bytes(original_bytes + b"# external remove change\n")
            return identity(path, expected)
        with mock.patch.object(recovery, "file_identity", side_effect=inject):
            with self.assertRaises(recovery.Failure): recovery.remove()
        self.assertIn("external remove change", config.read_text())
        recovery.snapshot()

    def test_remove_detects_change_after_replace_and_preserves_external_bytes(self):
        self.prepare(); config = self.esp / "limine.conf"
        original_replace = recovery.os.replace
        def replace_then_edit(source, target):
            original_replace(source, target)
            if Path(target) == config:
                config.write_bytes(config.read_bytes() + b"# external commit change\n")
        with mock.patch.object(recovery.os, "replace", side_effect=replace_then_edit):
            with self.assertRaises(recovery.Failure): recovery.remove()
        self.assertIn("external commit change", config.read_text())
        recovery.snapshot()

    def test_remove_cleanup_failure_is_committed_and_residue_is_reported(self):
        for point in ("remove-detached-payload", "remove-detached-state", "remove-config-backup"):
            with self.subTest(point=point):
                self.prepare(); config = self.esp / "limine.conf"
                errors = io.StringIO()
                with mock.patch.dict(os.environ, {"OMEN_ACPI_TEST_FAIL_CLEANUP": point}), \
                     redirect_stderr(errors):
                    recovery.remove()
                self.assertEqual(config.read_text(), self.original)
                self.assertFalse(recovery.STATE().exists())
                self.assertFalse((self.esp / "omen-acpi-stock-recovery").exists())
                self.assertIn("removal committed", errors.getvalue())
                for residue in (*self.esp.glob(".omen-acpi-stock-recovery.removed.*"),
                                *recovery.STATE().parent.glob(".omen-acpi-stock-recovery.removed.*"),
                                *self.esp.glob(".limine.conf.omen-remove-backup.*")):
                    if residue.is_dir(): shutil.rmtree(residue)
                    else: residue.unlink()

    def test_configuration_rollback_on_regeneration_failure(self):
        self.prepare(); config = self.esp / "limine.conf"
        without_normal = self.original[:self.original.index("/Linux-CachyOS")] + self.original[self.original.index("/User rescue"):]
        config.write_text(without_normal)
        with mock.patch.dict(os.environ, {"OMEN_ACPI_TEST_FAIL_REGENERATE": "1"}):
            with self.assertRaises(recovery.Failure): recovery.recover()
        self.assertEqual(config.read_text(), without_normal)

    def test_active_requires_stock_clean_exact_marker_and_valid_hashes(self):
        data = self.prepare(); proc = self.root / "proc"; proc.mkdir()
        (proc / "cmdline").write_text(f"quiet omen_acpi.stock_recovery={data['snapshot_id']}\n")
        recovery.active()
        with mock.patch.object(recovery, "probe", return_value={"STATE": "combined", "CLEAN": "0", "DSDT_REVISION": "0x0107200B"}):
            with self.assertRaises(recovery.Failure): recovery.active()
        (proc / "cmdline").write_text("quiet omen_acpi.stock_recovery=wrong\n")
        with self.assertRaises(recovery.Failure): recovery.active()

    def test_remove_preserves_unowned_content_and_blocks_only_stock_route(self):
        self.prepare(); config = self.esp / "limine.conf"
        recovery.remove()
        self.assertEqual(config.read_text(), self.original)
        self.assertFalse(recovery.STATE().exists())
        self.prepare()
        no_normal = self.original[:self.original.index("/Linux-CachyOS")] + "/zz-omen-acpi-s5-test\n protocol: linux\n kernel_path: boot():/x\n module_path: boot():/y\n"
        config.write_text(no_normal)
        with self.assertRaises(recovery.Failure): recovery.remove()

    def test_detailed_status_is_read_only_and_reports_required_fields(self):
        self.prepare()
        before_config = (self.esp / "limine.conf").read_bytes()
        before_manifest = (recovery.STATE() / "manifest.json").read_bytes()
        lock = self.root / "run/omen-acpi-fix/manager.lock"
        if lock.exists():
            lock.unlink()
        output = io.StringIO()
        with redirect_stdout(output):
            recovery.status()
        report = output.getvalue()
        for field in ("BOOT\tstock", "DSDT_REVISION\t", "DETECTION\t", "SNAPSHOT\tvalid",
                      "SNAPSHOT_CREATED\t", "SNAPSHOT_VERSION\t2.1.11", "KERNEL\t",
                      "MODULES\t2", "HASHES\tverified", "NORMAL_ENTRY\tavailable",
                      "RECOVERY_ENTRY\tmissing", "RECOMMENDATION\t"):
            self.assertIn(field, report)
        self.assertEqual((self.esp / "limine.conf").read_bytes(), before_config)
        self.assertEqual((recovery.STATE() / "manifest.json").read_bytes(), before_manifest)
        self.assertFalse(lock.exists())

    def test_status_contexts_are_fail_closed(self):
        config = self.esp / "limine.conf"
        output = io.StringIO()
        with redirect_stdout(output):
            recovery.status()
        self.assertIn("SNAPSHOT\tmissing", output.getvalue())

        self.prepare()
        config.write_text(self.original[:self.original.index("/Linux-CachyOS")] + self.original[self.original.index("/User rescue"):])
        output = io.StringIO()
        with redirect_stdout(output):
            recovery.status()
        self.assertIn("NORMAL_ENTRY\tmissing", output.getvalue())
        self.assertIn("SNAPSHOT\tvalid", output.getvalue())

        config.write_text(self.original + self.original[self.original.index("/Linux-CachyOS"):self.original.index("/User rescue")])
        before = config.read_bytes()
        output = io.StringIO()
        with redirect_stdout(output):
            recovery.status()
        self.assertIn("NORMAL_ENTRY\tambiguous", output.getvalue())
        self.assertEqual(config.read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
