# Preventive stock recovery

This document describes the stock-recovery state machine and transaction rules
implemented by OMEN ACPI Toolkit v2.3.0. The minimum safe workflow and the
irreducible recovery limitation remain in the packaged `README.md`.

## Components and status

The preventive snapshot consists of one indivisible managed pair:

- reserved ESP payload directory `boot():/omen-acpi-stock-recovery/`;
- root-owned manifest directory `/var/lib/omen-acpi-stock-recovery`.

The optional Limine entry is named `zz-omen-acpi-stock-recovery`. It is created
only when the normal stock entry is missing and a current trusted snapshot can
be verified. It points exclusively at the reserved copies.

The recovery menu reports these snapshot states:

| State | Meaning |
| --- | --- |
| `valid` | Current trusted manifest and all payloads pass ownership and integrity checks. |
| `refresh-required` | An owned legacy snapshot is intact enough to inspect or remove but is not trusted for boot. |
| `missing` | Both managed snapshot components are absent. |
| `stale` | Snapshot payloads do not match the current usable normal source. |
| `modified` | Pair, ownership, integrity, type, mode or reserved-content checks failed. |
| `unavailable` | The manager could not classify state safely. |

Normal-entry status is `available`, `missing`, `ambiguous`, `unusable` or
`unavailable`. Recovery-entry status is `available`, `legacy-untrusted`,
`missing`, `modified` or `unavailable`.

The dashboard key `r` opens **Stock boot and recovery** independently of a
pending setup workflow. The submenu has no default action:

```text
Stock boot and recovery

Current boot: <current state>
Preventive snapshot: <snapshot state>
Normal stock entry: <normal-entry state>
Managed recovery entry: <recovery-entry state>

  1. Create or refresh the preventive recovery snapshot
  2. Recover or reboot into a stock boot
  3. Show detailed recovery status
  4. Remove the managed recovery snapshot and entry
  b. Back

Selection:
```

Options that write or reboot require explicit confirmation. Detailed status is
read-only. Contextual recommendations never execute an action automatically.

## Snapshot preparation

`omen-acpi prepare-stock-recovery` works only during a validated or explicitly
opted-in, clean and verified stock boot. It recognizes primary
`linux-cachyos` and `linux-cachyos-lts` entries in the active namespace,
selects standard first when both are usable (otherwise LTS), copies that
entry's kernel and every `module_path` in original order, and creates a
kernel-bound manifest.

The manifest records schema and toolkit versions, creation time, DMI, board,
BIOS, stock DSDT revision and SHA-256, source title, kernel version, normalized
configuration, original and reserved paths, command line, and each payload's
size and SHA-256. Metadata is parsed as JSON without `eval`. Reserved filenames
are deterministic and never derived from entry titles or command lines.

Preparation rejects:

- S5, Combined, legacy, unknown or unavailable active boots;
- DMI that is missing, unreadable, changed since the snapshot, or unvalidated
  without the current process's explicit opt-in;
- missing, duplicated, cross-namespace or unusable supported stock entries;
- unsafe, non-canonical or changing paths;
- symlinks, hard links and unexpected file types;
- initramfs containing `kernel/firmware/acpi/`;
- payload hashes matching a managed variant, regardless of filename;
- a source, configuration or previous snapshot that changes during staging.

Every initramfs is inspected with `lsinitcpio`. Staged bytes are inspected
directly, and every staged digest is bound to the initially validated source
identity and digest. The complete source and normalized configuration are
revalidated before activation.

Guided setup and variant installation prepare the snapshot only after the
requested variant schema is known to be absent. An installed, legacy or
conflicting variant cannot use installation as an implicit snapshot refresh.

## Pair ownership and legacy compatibility

Preparation permits both snapshot components to be absent, or requires both to
pass strict ownership and integrity verification before refresh. A lone
directory, regular file, symlink—including a broken symlink—unsafe mode or
foreign content is `modified`. It is never renamed, repaired, replaced or
deleted automatically.

Version 2.1.11 reference snapshots remain trusted only on the exact reference
identity. Version 2.1.10 snapshots remain ownership- and integrity-checked but
are not trusted for boot and are reported as `refresh-required`. While a valid normal entry
still exists, the legacy pair can be preserved for a normal confirmed reboot,
refreshed from a subsequent clean stock boot or explicitly removed.

Only a current trusted snapshot can create or validate the managed recovery
entry. If the normal entry is missing, ambiguous or unusable and only a legacy
snapshot remains, external recovery media is required.

## Recovery outcomes

`omen-acpi recover-stock` has three outcomes:

1. On an already clean stock boot, it reports success without changing or
   rebooting anything.
2. If any supported stock entry and all referenced payloads pass full
   stock-source validation, it preserves every stock entry and offers the same confirmed reboot as
   `reboot-stock`.
3. If the normal entry is gone, it verifies the complete current trusted
   snapshot and creates only `zz-omen-acpi-stock-recovery`. Other entries,
   global settings, comments, order and default remain unchanged. Reboot still
   requires confirmation and names the entry to select.

`omen-acpi reboot-stock` is deliberately narrower. It finds an existing
standard entry, or LTS when standard is absent, and can request a one-time reboot after confirmation. It never creates or
changes an entry.

Status recommends preparation only during a clean stock boot with no snapshot
and a fully usable normal source. A missing, ambiguous, unusable or unverifiable
source must be restored and verified first.

## Transaction boundaries

Staging and `fsync` occur on destination filesystems. Activation uses atomic
no-replace renames. The previous payload/manifest pair is reloaded and must
retain the same snapshot identity immediately before any rename. The complete
new pair commits before old-backup cleanup; if cleanup fails, the new valid
snapshot remains committed and the safely named residue is reported.

Recovery-entry creation and removal preserve the exact initially read
`limine.conf` bytes and recheck file identity, content and metadata after backup
and immediately before replacement. External modification is never silently
overwritten. The toolkit advisory lock serializes its own operations, while
post-replacement verification protects against programs that ignore the lock.

Creation reloads the same trusted snapshot immediately before the configuration
commit. At the final boundary it checks the original `limine.conf` again,
replaces it, and revalidates both the trusted snapshot and exact installed
configuration before deleting the backup.

Removal binds the initially owned snapshot, checks the exact pair before and
after configuration replacement, and uses no-replace detached destinations.
The normal kernel and every normal initramfs must remain a usable stock source
before replacement, after replacement and after recovery-state detachment. If
a source disappears, changes identity or content, gains a link, contains an
ACPI override or matches a managed variant, removal aborts and restores the
owned pair.

Stage and backup files are created exclusively. Concurrent files, directories
or symlinks at reserved transaction paths are preserved and block the operation.
A changed snapshot component, new foreign file or occupied rollback path aborts
without deleting the object that appeared concurrently.

## Recovery entry integrity

The recovery entry carries a snapshot-bound marker. The dashboard displays
`STOCK RECOVERY ACTIVE` only when that marker matches a root-owned,
integrity-checked current trusted manifest and all payload hashes, while the
active DSDT independently classifies as clean stock revision `0x01072009`.

The marker cannot mask S5, Combined or an unknown DSDT. An owned legacy entry
is not upgraded to trusted merely because its payloads are internally
consistent.

## Explicit removal

`omen-acpi remove-stock-recovery` removes the owned recovery entry, payloads
and manifest only after exact checks. It accepts a current or legacy owned
snapshot, but always requires one unambiguous normal entry whose kernel and all
initramfs are regular, stable, canonical, present, single-linked and verified
free of ACPI overrides and managed-variant payloads.

Removal does not require the active boot or current BIOS to match stock, but it
does require the usable normal source. The uninstaller refuses to proceed while
recovery state remains or while removal would orphan the only stock route.

## Irreducible limit

This mechanism preserves known-good stock bytes; it does not reconstruct them.
Create or refresh the current trusted snapshot while at least one supported
stock kernel and its payloads still exist. The manifest remains bound to that
exact standard/LTS source even if the other kernel is installed later. If
currently booted in a variant, use
`omen-acpi reboot-stock`, boot the normal entry, and prepare the snapshot there.

If the normal entry has already disappeared and no current trusted snapshot
exists, automatic recovery is impossible. `limine.conf.before`, a legacy
snapshot and variant initramfs are deliberately insufficient. Restore the
normal boot path with external manual recovery media.
