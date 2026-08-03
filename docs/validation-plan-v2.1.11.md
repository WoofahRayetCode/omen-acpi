# Manual validation plan for 2.1.11 (not executed)

Copyright (C) 2026 Paolo De Marinis
SPDX-License-Identifier: GPL-3.0-or-later

This plan has **not been executed on real hardware**. Perform it only on the
documented HP OMEN MAX 16-ap0006sl reference machine, with board `8E35`, BIOS
`F.13`, the normal CachyOS entry intact and external bootable recovery media.

1. Confirm the exact DMI, board, BIOS, Hybrid graphics mode, NVIDIA PCI address,
   disabled Secure Boot and `CONFIG_ACPI_TABLE_UPGRADE=y` prerequisites.
2. From a verified clean stock boot, hash `limine.conf` and prepare a preventive
   stock snapshot. Verify every payload against `manifest.json` and confirm the
   normal entry, order and default are unchanged.
3. On an expendable ESP fixture, repeat preparation with a managed composite
   initramfs renamed `initramfs-linux-cachyos.img`; confirm rejection preserves
   the previous complete snapshot.
4. Inject cleanup failures after activation of a refreshed snapshot. Confirm the
   new payload and manifest remain mutually valid and every leftover backup is
   hidden, safely named and reported by a warning.
5. Test recovery-entry creation and removal on an expendable ESP copy with
   marker loss, one marker, duplicate markers, duplicate reserved titles and a
   one-field entry modification. Every ambiguous case must leave all bytes and
   managed state unchanged.
6. Inject an external `limine.conf` modification during the backup and final
   commit windows of both recover and remove. Confirm the operation fails, the
   external bytes remain and the previous recovery state stays complete.
7. With an existing and then a conflicting S5/Combined fixture, enter Guided
   setup and confirm variant schema rejection happens before any recovery
   snapshot refresh.
8. Run `update.sh --verify-only` as a normal user with a new temporary HOME and
   confirm it creates no persistent updater command and never invokes install.
9. Run the complete automated verification matrix, build the release archive
   twice, compare it byte-for-byte, and retain its SHA-256 for independent audit.
10. Only after these checks, install S5 and Combined independently and verify
    their transformations and OEM revisions remain `0x0107200A` and
    `0x0107200B`; return to stock between tests and exercise removal separately.
11. With a synthetic, ownership-valid 2.1.10 snapshot, confirm status reports
    `refresh-required`, recovery boot creation and active recognition are
    blocked, and a clean stock boot refreshes it to a trusted 2.1.11 snapshot.
12. Remove current and legacy owned snapshots only while one valid normal
    `linux-cachyos` entry exists. Repeat with that entry missing and ambiguous;
    confirm configuration, manifest and payload bytes remain unchanged.
13. On expendable filesystem fixtures, create every incomplete combination of
    ESP recovery payload and `/var/lib` state, including regular files, valid
    and broken symlinks and unsafe directory modes. Confirm status says
    `modified` and prepare/uninstall neither rename nor delete any path.
14. From simulated S5 and Combined boots and with a changed BIOS fixture,
    remove owned 2.1.10 and 2.1.11 snapshots only when the normal entry's real
    kernel and initramfs payloads pass stable identity, hash and `lsinitcpio`
    checks. Inject each unusable-source case and confirm all owned bytes remain.
15. With a `refresh-required` 2.1.10 fixture and a usable normal entry, select
    recovery option 2 and confirm it reaches the explicit normal-stock reboot
    prompt without creating a recovery entry. Repeat with missing, ambiguous
    and unusable entries and confirm external media is required.
16. During snapshot refresh, replace the normal kernel and each initramfs in
    turn after initial validation, after its staged copy and before activation.
    Confirm staged initramfs inspection, source fingerprints and the final
    normalized-source comparison reject every mixed-generation snapshot while
    preserving the previous payload/manifest pair byte-for-byte.
17. Inject new files, valid and broken symlinks and changed payloads into the
    owned snapshot immediately before prepare and remove mutation boundaries.
    Occupy every `.old` and `.removed` destination. Confirm no-replace renames
    preserve the foreign objects, `limine.conf` rolls back exactly and no
    toolkit staging path remains.
18. Remove the normal entry from an expendable configuration, then modify the
    trusted snapshot after recovery-entry staging but before configuration
    commit. Confirm the entry is not created, the external snapshot change is
    preserved and the original `limine.conf` bytes are restored.
