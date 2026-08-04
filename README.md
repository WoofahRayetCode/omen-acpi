# OMEN ACPI Toolkit

## About

OMEN ACPI Toolkit is a guided, machine-specific Linux ACPI reproduction for
one reference laptop. On that machine the firmware does not run its discrete-GPU
power-down path while preparing S5, so the laptop can appear to shut down while
the NVIDIA GPU remains powered, drawing current and producing heat.

The toolkit builds a replacement DSDT that extends `_PTS`, installs it in a
**separate experimental Limine entry**, and leaves the normal boot entry
untouched.

> **This is not a generic HP OMEN fix.** It targets one exact retail model,
> board and BIOS revision. Version 2.1.11 has no opt-in or bypass for other
> hardware. Read [Risks and limits](#risks-and-limits) before using it.

## Validated reference hardware

The maintainer has physically validated only this configuration:

| Property | Validated value |
| --- | --- |
| Retail model | HP OMEN MAX 16-ap0006sl |
| DMI product name | `OMEN Gaming Laptop 16-ap0xxx` |
| Mainboard | `8E35` |
| BIOS | `F.13` |
| Distribution | CachyOS |
| Kernel | `7.1.5-1-cachyos` |
| ESP | `/boot` |
| Secure Boot | disabled |
| Normal Limine entry | `linux-cachyos` |

`OMEN Gaming Laptop 16-ap0xxx` is a DMI identifier shared by a model family.
It does **not** establish compatibility with every SKU in that family. No other
model, SKU, board or BIOS is validated or supported.

Both variants, normal installation and removal, return to stock, and preventive
recovery creation, removal and recreation were tested on the reference machine.
Version 2.1.11 accepts only the exact supported identity: an experimental
hardware opt-in is not available. If any identity value differs, do not try to
bypass the checks.

The toolkit was developed for CachyOS/Arch Linux with mkinitcpio and Limine.
Strict product, board, BIOS, GPU and ACPI-structure checks reduce accidental
misapplication; they do not prove compatibility.

## Validation scope

On 4 August 2026 the maintainer booted both managed variants on the reference
machine. Each loaded the intended managed DSDT. The verified S5-only and
Combined shutdowns completed without the previous abnormal post-shutdown
heating. The verified Combined boot also passed the BF01/WQBZ check without
related `AE_AML_BUFFER_LIMIT`, `WQBZ` or `WQBE` messages.

The normal `recover-stock` route returned from Combined to the unchanged
`linux-cachyos` entry. The preventive snapshot was created, removed and
recreated on the real filesystem; `limine.conf` remained byte-for-byte
identical and no transactional residue remained.

Destructive, corruption, collision, failure-injection and concurrent-race
scenarios were intentionally limited to automated fixtures. The normal entry
was not deleted on the physical machine, and no recreated emergency recovery
entry was booted there. Automated tests do not demonstrate compatibility with
other hardware. The complete boundary is recorded in the
[versioned validation record](https://github.com/paolo-de-marinis/omen-acpi/blob/v2.1.11/docs/validation.md).

## Operational scope

The toolkit collects the machine's own ACPI tables locally during a verified
clean stock boot, applies a normalized transformation, compiles and checks the
result, and creates a separate experimental entry with its own initramfs. It
reports the active DSDT and integrity of managed state, and removes only objects
that pass exact ownership checks.

It does not:

- flash or modify the BIOS;
- replace, reorder, hide or make non-default the normal CachyOS entry;
- make an experimental entry the default;
- modify suspend, S0ix or runtime power management;
- distribute firmware tables collected from a machine;
- enable or bypass Secure Boot.

Collection, build and installation fail closed when the machine, active boot,
firmware structure, generated AML or existing managed state cannot be verified.
This reduces accidental changes; it cannot make an ACPI override risk-free.

## Patch variants

Both variants are **experimental** and are installed independently. Stock
firmware reports DSDT OEM revision `0x01072009`.

### `s5` — NVIDIA S5 power-off correction

- Managed OEM revision: `0x0107200A`
- Limine entry: `zz-omen-acpi-s5-test`
- Root state: `/var/lib/omen-acpi-s5-test`

For `Arg0 == 5`, the transformation extends `_PTS` with the firmware's existing
power-down sequence:

```text
PEGP.OMPR = 3
PEGP._PS3()
```

It does not write `NVDE` and does not alter suspend, S0ix or runtime power
management. This is the variant confirmed to correct the incomplete S5
shutdown on the reference machine and is the recommended first test.

### `combined` — S5 plus WQBZ buffer bounds

- Managed OEM revision: `0x0107200B`
- Limine entry: `zz-omen-acpi-combined-test`
- Root state: `/var/lib/omen-acpi-combined-test`

Combined contains the complete S5 correction and bounds two affected `WQBZ`
loops before they dereference `BF01[Local5]`. The WQBZ issue is separate from
shutdown. This variant loaded successfully and removed the observed
`AE_AML_BUFFER_LIMIT` error on the reference machine, but it still requires
independent regression testing on every firmware revision—which this project
does not support.

The normalized transformations and structural checks are documented in
[`patches/README.md`](patches/README.md).

## Requirements

- The exact reference model, DMI identity, board and BIOS listed above.
- Hybrid firmware graphics mode and the NVIDIA GPU at `0000:01:00.0`.
- A kernel with `CONFIG_ACPI_TABLE_UPGRADE=y`.
- Secure Boot disabled; the toolkit signs nothing and cannot work around it.
- Limine with `limine-entry-tool` and an existing normal CachyOS entry.
- CachyOS/Arch Linux package management, mkinitcpio and Python 3.
- ACPI and build tools including `acpidump`, `acpixtract`, `iasl`, `cpio`,
  `lsinitcpio`, `findmnt`, `flock`, `tar`, `gzip`, `sha256sum` and `sudo`.
- Enough ESP space for one additional kernel and initramfs per variant, plus
  the preventive stock-recovery copies.

The CLI checks operation-specific commands and can offer to install missing
repository packages. It blocks partial system upgrades and never invokes an
AUR helper.

## Installation

Use only the three published v2.1.11 assets. If these URLs return 404, the
Release is not available; do not install from a source snapshot.

```bash
curl -LO https://github.com/paolo-de-marinis/omen-acpi/releases/download/v2.1.11/omen-acpi-toolkit-v2.1.11.tar.gz
curl -LO https://github.com/paolo-de-marinis/omen-acpi/releases/download/v2.1.11/omen-acpi-toolkit-v2.1.11.tar.gz.sha256
sha256sum -c omen-acpi-toolkit-v2.1.11.tar.gz.sha256
tar xzf omen-acpi-toolkit-v2.1.11.tar.gz
cd omen-acpi-toolkit-v2.1.11
sha256sum -c SHA256SUMS
sudo ./install.sh
omen-acpi
```

The adjacent `.tar.gz.sha256` verifies the downloaded archive. The internal
`SHA256SUMS` then verifies every release file. Both checks must pass.

Do **not** run `sudo omen-acpi`. The frontend stays unprivileged and requests
administrator access only for package installation, restricted ACPI
inspection, Limine changes or reboot.

## Minimum safe workflow

The default command opens a state-aware dashboard:

```bash
omen-acpi
```

Choose **Guided setup**. The CLI verifies the machine, dependencies and current
boot; requires a clean stock boot; prepares a preventive stock snapshot;
collects and fingerprints the local DSDT; builds and verifies the selected
variant; and creates a separate Limine entry. It never silently selects a
variant or changes the default boot entry.

Start with S5-only unless you specifically need to test the separate WQBZ
bounds change. Both variants can coexist:

```bash
omen-acpi setup s5
omen-acpi setup combined
omen-acpi setup both
```

After setup, reboot and manually select the requested experimental entry. Then
inspect the active DSDT and managed state:

```bash
omen-acpi status all
```

Status compares the active DSDT with managed AML, verifies the entry and stored
state, detects stale kernel/initramfs snapshots, and reports relevant Combined
boot messages.

For a shutdown test, save all work, disconnect external displays and preferably
the AC adapter, then use the desktop shutdown action or:

```bash
sync && systemctl poweroff
```

Keep the laptop on a hard surface and check that it cools completely. Do not
make an experimental entry the default.

The full command reference, dashboard modes, dependency handling, lifecycle,
private artifacts and troubleshooting are in the
[v2.1.11 usage guide](https://github.com/paolo-de-marinis/omen-acpi/blob/v2.1.11/docs/usage.md).

## Boot entries

The toolkit preserves the bootloader entries that already exist and adds only
its reserved entries:

| Entry | Purpose |
| --- | --- |
| normal CachyOS entry, normally `linux-cachyos` | unchanged stock firmware DSDT |
| `zz-omen-acpi-s5-test` | kernel snapshot with the S5-only DSDT override |
| `zz-omen-acpi-combined-test` | kernel snapshot with the Combined DSDT override |
| `zz-omen-acpi-stock-recovery` | verified stock kernel/initramfs copies, created only when needed |

The normal entry is never replaced, reordered, hidden or made non-default.
Experimental entries are additions and must be selected manually on each boot.
The recovery entry is not a general-purpose replacement for the normal entry.

## Preventive stock recovery

Before installing a variant, the toolkit prepares a recovery snapshot from one
unambiguous, usable normal entry during an exactly supported, clean stock boot.
It copies the normal kernel and every initramfs component to the ESP and stores
a root-owned manifest under `/var/lib/omen-acpi-stock-recovery`. Payload sizes,
SHA-256 hashes, source identity, boot configuration and machine identity are
verified fail-closed.

Open the recovery menu with `r` in the dashboard, or use:

```bash
omen-acpi prepare-stock-recovery
omen-acpi recover-stock
omen-acpi reboot-stock
omen-acpi remove-stock-recovery
```

The important states are:

- `valid`: a current trusted snapshot is intact;
- `refresh-required`: an owned legacy snapshot can be inspected or removed but
  is not trusted to recreate a boot entry;
- `missing`: the managed snapshot pair is absent;
- `stale`: stored stock payloads no longer match the usable normal source;
- `modified`: ownership, integrity, type or pair checks failed;
- `unavailable`: status could not be established safely.

Legacy snapshots remain ownership- and integrity-checked but are never trusted
for boot. They must be refreshed from a clean stock boot before they can support
automatic recovery-entry creation.

`recover-stock` changes nothing on an already clean stock boot. If one usable
normal entry still exists, it preserves it and can offer an explicitly
confirmed reboot. Only when that entry is missing can a **current trusted**
snapshot create `zz-omen-acpi-stock-recovery`; the toolkit preserves all other
configuration and still requires explicit reboot confirmation.

Snapshot preparation, recovery-entry changes and removal validate stable files,
reject ACPI overrides and managed-variant payloads, serialize toolkit
operations, preserve exact `limine.conf` bytes across checks, and abort on
ambiguous, foreign or concurrently changed state. A lone payload or manifest,
unsafe type, unexpected link, invalid hash or occupied transaction path is
reported as modified and is not repaired or deleted automatically.

This is preventive recovery, not reconstruction. If both the normal entry and
a current trusted snapshot are unavailable, the toolkit cannot manufacture
stock kernel or initramfs data. A variant initramfs and `limine.conf.before` are
insufficient: **external manual recovery media is required**.

Do not remove the snapshot until one unambiguous normal stock entry and all of
its payloads pass validation. The complete state model, manifest, transaction,
rollback, race and legacy rules are in the
[v2.1.11 recovery guide](https://github.com/paolo-de-marinis/omen-acpi/blob/v2.1.11/docs/recovery.md).

## Returning to stock

Select the normal CachyOS entry in Limine. The DSDT override exists only in an
experimental entry's initramfs, so no further action is needed.

From the CLI, this command only finds an existing normal entry and offers a
confirmed reboot; it never creates or modifies an entry:

```bash
omen-acpi reboot-stock
```

If the normal entry is missing, use `omen-acpi recover-stock` only when a
current trusted snapshot exists. The toolkit fails closed when the active DSDT,
kernel messages, taint state, managed AML or saved stock fingerprint disagree.

## Updating

Running `sudo ./install.sh` over an installation updates the program and
installed documentation. It does not rewrite `/var/lib` variant state, Limine
entries, command-line drop-ins or the ESP.

The separate `update.sh` verifies both checksum layers, blocks downgrades and
invokes the transactional installer. It can verify a colocated release without
installing it:

```bash
./update.sh --verify-only
```

Managed entries contain the normal kernel and initramfs snapshot present when
they were created. After every kernel, initramfs or Limine update, recreate
them rather than updating them in place:

```bash
omen-acpi remove all
omen-acpi install both
```

Install only the variants you intend to keep; replace `both` accordingly. A
legacy entry is reported as `LEGACY / REINSTALL`. Modified or mixed state is
reported as `CONFLICT / BLOCKED` and is never changed automatically.

## Removal

First return to the normal stock entry. Remove either variant or both:

```bash
omen-acpi remove s5
omen-acpi remove combined
omen-acpi remove all
```

Removal touches only owned state for the selected variant. It does not change
the BIOS DSDT, normal entry or other variant. Removing an active variant cannot
unload its DSDT from the running kernel, which is why a stock boot is required
before new collection.

To remove the toolkit completely:

```bash
omen-acpi remove-stock-recovery
omen-acpi uninstall
```

Snapshot removal requires a usable normal entry. The uninstaller refuses to
orphan managed Limine entries, refuses while recovery state remains, and
preserves private user artifacts. It also blocks removal when the recovery
entry is the only remaining stock route and experimental variants are still
installed.

## Risks and limits

**This project is experimental and modifies ACPI behaviour during boot.** A
firmware, kernel or bootloader mismatch can cause boot failure, data loss,
system instability, abnormal thermal behaviour, powered-off battery drain or
the need for manual recovery. An incorrect DSDT can prevent Linux from booting.

- Use it exclusively on HP OMEN MAX 16-ap0006sl with DMI
  `OMEN Gaming Laptop 16-ap0xxx`, board `8E35` and BIOS `F.13`.
- A shared DMI family name is not evidence that another SKU is compatible.
- Version 2.1.11 has no experimental hardware opt-in. Other hardware is
  unvalidated and unsupported.
- Secure Boot must remain disabled; the toolkit signs nothing.
- Always retain a working normal stock entry and know how to select it.
- Never make an experimental entry the default before repeated successful
  testing.
- Save all work before boot and shutdown tests.
- The S5 correction depends on firmware power-resource state.
- Combined is not regression-tested across other firmware revisions.
- Recreate managed entries after kernel, initramfs or Limine updates.
- Preventive recovery works only when a trusted snapshot was prepared before
  the normal entry was lost.
- A BIOS update invalidates every hardware and firmware assumption here.
- Use is entirely at your own risk.

Generated firmware-derived archives are private by default. Do not publish
them without reviewing their contents. No ACPI dump, compiled table, initramfs,
Limine configuration, serial number, UUID or OEM key is distributed by this
repository.

The complete real-hardware and synthetic-test boundary is in the validation
record linked above. Background analysis and external reports do not extend
the supported hardware set.

## Development process

This project was developed through a substantially AI-assisted workflow using
OpenAI Codex. Codex generated significant portions of the Bash and Python
implementation, automated tests and documentation, and was used for code review
and ACPI-analysis workflows under iterative direction from the maintainer.

The maintainer identified and reproduced the hardware problem, supplied the
machine observations, executed the documented real-hardware boot, shutdown and
recovery tests, and made the final publication decisions.

The code has not received independent human review by an ACPI or
systems-programming specialist. AI-generated tests and reviews do not constitute
independent assurance, and no formal security audit is claimed.

## Documentation

- [Usage guide](https://github.com/paolo-de-marinis/omen-acpi/blob/v2.1.11/docs/usage.md): complete CLI reference, lifecycle, dependencies, artifacts and troubleshooting.
- [Recovery guide](https://github.com/paolo-de-marinis/omen-acpi/blob/v2.1.11/docs/recovery.md): snapshot formats, states, transactions, rollback and recovery limits.
- [Technical references](https://github.com/paolo-de-marinis/omen-acpi/blob/v2.1.11/docs/references.md): standards, reports, prior art and project-specific analysis.
- [Validation record](https://github.com/paolo-de-marinis/omen-acpi/blob/v2.1.11/docs/validation.md): current real-hardware, automated and synthetic-only scope.

These files are repository documentation and are not included in the release
archive. The README itself contains the complete safety-critical installation,
stock-return, recovery-limit and removal instructions needed to operate the
packaged toolkit.

## License and affiliation

Copyright (C) 2026 Paolo De Marinis

This program is free software under the GNU General Public License version 3 or
later. It is provided **without any warranty**, to the extent permitted by law.
See sections 15, 16 and 17 of [`LICENSE`](LICENSE) for warranty and liability
terms. The author and contributors are not liable, to the maximum extent
permitted by law, for loss, boot failure, hardware damage or other effects of
use. This risk summary adds no terms to the GPL.

Firmware tables extracted locally remain subject to their respective rights
and are not distributed by this repository.

This project is not affiliated with, endorsed by or supported by HP, NVIDIA,
AMD, Arch Linux, CachyOS or the Limine project. Product names and trademarks
belong to their respective owners.
