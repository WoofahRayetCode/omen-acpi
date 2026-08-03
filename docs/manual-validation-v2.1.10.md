# Manual validation plan for 2.1.10 (not executed)

This plan is intentionally conservative. Keep `linux-cachyos` intact for the
entire initial validation and keep external bootable recovery media available.

1. Verify the exact supported DMI product, board `8E35`, BIOS `F.13`, Secure
   Boot state, current `linux-cachyos` entry and a clean stock DSDT.
2. Record hashes and a copy of the current Limine configuration outside the
   ESP for comparison only; do not use it as an automatic restore source.
3. Run `omen-acpi prepare-stock-recovery` while booted through the untouched
   normal entry. Inspect `/var/lib/omen-acpi-stock-recovery/manifest.json` and
   verify every payload/hash under `boot():/omen-acpi-stock-recovery/`.
4. Run `omen-acpi recover-stock` while the normal entry still exists and prove
   byte-for-byte that it does not modify `limine.conf`.
5. In a temporary copy of the configuration, review the exact reserved entry
   that recovery would create. Do not delete or rename `linux-cachyos` yet.
6. Install one experimental variant, boot it, and confirm the snapshot did not
   change. Confirm `reboot-stock` identifies only the original normal entry.
7. Return to stock and verify normal status. Separately exercise the recovery
   entry while retaining `linux-cachyos`; confirm `STOCK RECOVERY ACTIVE`, the
   stock DSDT revision/hash, and every snapshot payload hash.
8. Test idempotent recovery creation and removal only after proving the normal
   entry remains independently usable. Confirm global settings, comments,
   default and all unrelated entries are unchanged.
9. Test tamper failures one at a time using expendable copies or a dedicated
   test ESP, never the only boot path. Verify rollback after each injected
   failure.
10. Consider deletion of the normal entry only in a later, separately approved
    destructive test with external recovery media and a verified recovery
    entry. It is outside this initial validation plan.
