# OMEN ACPI Toolkit

A guided, machine-specific Linux ACPI reproduction for one reference laptop.

On the reference machine the firmware never runs its own discrete-GPU power-down
path while preparing S5. The laptop therefore "shuts down" with the NVIDIA GPU
still powered: it keeps drawing current and stays warm with the lid closed. This
toolkit builds a replacement DSDT that extends `_PTS` so the firmware's existing
power-down sequence is executed during S5, installs it as a **separate**
experimental Limine entry, and leaves the normal boot entry untouched.

> **This is not a generic HP OMEN fix.** It targets exactly one model, board and
> BIOS revision. Read [Safety and disclaimer](#safety-and-disclaimer) before you
> use it.

## Supported hardware

| Property | Required value |
| --- | --- |
| Retail model | HP OMEN MAX 16-ap0006sl |
| DMI product name | `OMEN Gaming Laptop 16-ap0xxx` |
| Mainboard | `8E35` |
| BIOS | `F.13` |
| Firmware graphics mode | `Hybrid` |
| NVIDIA PCI address | `0000:01:00.0` |
| Secure Boot | disabled |

Developed and tested on **CachyOS/Arch Linux** with **mkinitcpio** and
**Limine**. The kernel must be built with `CONFIG_ACPI_TABLE_UPGRADE=y`.

The DMI product name covers a model family. Strict product, board, BIOS, GPU and
ACPI-structure checks reduce the risk of applying the patch elsewhere, but they
do not prove compatibility with every retail SKU.

## What it does

- Collects the machine's own firmware ACPI tables locally, only while a clean
  stock DSDT is booted.
- Applies a normalized, auditable transformation to the decompiled DSDT.
- Compiles and independently verifies the result before anything is installed.
- Creates a separate experimental Limine entry with its own initramfs.
- Reports the active boot state and the integrity of everything it installed.
- Removes what it installed, after exact ownership checks.

## What it does not do

- It does not flash or modify the BIOS.
- It does not replace, reorder or hide the normal CachyOS entry.
- It never makes an experimental entry the default.
- It does not modify suspend, S0ix or runtime power management.
- It does not distribute any firmware table: everything is derived on your own
  machine, from your own firmware.
- It does not work around Secure Boot.

## Patch variants

Both variants are **experimental**. They are distinguished at runtime by the
DSDT OEM revision, which is the field the toolkit and the kernel use to tell the
active table apart from the stock one. Stock firmware reports `0x01072009`.

### `s5` — NVIDIA S5 power-off correction

- Patched OEM revision: `0x0107200A`
- Limine entry: `zz-omen-acpi-s5-test`
- Root state: `/var/lib/omen-acpi-s5-test`

Extends `_PTS` only for `Arg0 == 5`. After the firmware's original preparation
calls it performs, in order:

```text
PEGP.OMPR = 3
PEGP._PS3()
```

This is the exact ACPI operation sequence that was tested successfully on the
reference machine. It activates the firmware's existing discrete-GPU power-down
path without calling the underlying power resource directly. It does not write
`NVDE`, and it does not alter suspend, S0ix or runtime power management.

This is the variant confirmed to solve the incomplete S5 shutdown on the
reference machine, and the recommended first test.

### `combined` — S5 plus WQBZ buffer bounds

- Patched OEM revision: `0x0107200B`
- Limine entry: `zz-omen-acpi-combined-test`
- Root state: `/var/lib/omen-acpi-combined-test`

Contains the complete S5 correction and additionally bounds the two affected
`WQBZ` loops before dereferencing `BF01[Local5]`. It preserves the original
zero-terminated behaviour while preventing the observed out-of-range access at
index `0x32` of a `0x32`-byte buffer.

The WQBZ problem is separate from the shutdown problem. The combined table
loaded successfully and removed the observed `AE_AML_BUFFER_LIMIT` error on the
reference machine, but it should still be regression-tested independently.

Both variants may be installed at the same time and remain fully independent.
The normalized transformations are documented in
[`patches/README.md`](patches/README.md).

## Requirements

- The exact hardware and BIOS listed above.
- A kernel with `CONFIG_ACPI_TABLE_UPGRADE=y`.
- Secure Boot disabled.
- Limine as the bootloader, with `limine-entry-tool`.
- The build and inspection commands listed under [Dependencies](#dependencies).
- Enough free space on the EFI system partition for one extra kernel and
  initramfs per installed variant.

## Installation

Download the release assets, verify both checksum layers, then install:

```bash
curl -LO https://github.com/paolo-de-marinis/omen-acpi/releases/download/v2.1.9/omen-acpi-toolkit-v2.1.9.tar.gz
```

```bash
curl -LO https://github.com/paolo-de-marinis/omen-acpi/releases/download/v2.1.9/omen-acpi-toolkit-v2.1.9.tar.gz.sha256
```

```bash
sha256sum -c omen-acpi-toolkit-v2.1.9.tar.gz.sha256
```

```bash
tar xzf omen-acpi-toolkit-v2.1.9.tar.gz && cd omen-acpi-toolkit-v2.1.9
```

The archive carries a second, per-file manifest. Verify it too:

```bash
sha256sum -c SHA256SUMS
```

Then install the single public command:

```bash
sudo ./install.sh
```

```bash
omen-acpi
```

Do **not** run `sudo omen-acpi`. The interactive frontend stays unprivileged and
requests administrator access only for package installation, restricted ACPI
inspection, Limine changes or reboot.

Command examples in this document are written for Bash. They work unchanged in
Fish except for shell-specific syntax; where a command needs adapting, it is
noted inline.

## Using `omen-acpi`

The default interface is a state-aware dashboard:

```text
+ OMEN ACPI Toolkit v2.1.9 ----------------------------------------------+
|  Machine       8E35 / BIOS F.13      READY                             |
|  Dependencies  All commands          READY                             |
|  Current boot  0x01072009            STOCK / SAFE                      |
|  S5-only       Limine test entry     NOT INSTALLED                     |
|  Combined      S5 + WQBZ entry       NOT INSTALLED                     |
+------------------------------------------------------------------------+
```

Choose **Guided setup**. The CLI will:

1. verify the exact machine and BIOS;
2. find missing dependencies and offer to install them with Pacman;
3. inspect the currently loaded ACPI state;
4. require a clean stock boot before collecting firmware source;
5. privately collect and fingerprint the original DSDT;
6. build and independently verify the selected variant;
7. transactionally create a separate Limine test entry;
8. offer a reboot and tell you exactly which entry to select.

The same operations are available as explicit subcommands:

```text
omen-acpi setup [s5|combined|both]
omen-acpi doctor [--fix]
omen-acpi dependencies [--install]
omen-acpi collect
omen-acpi build <s5|combined|both> [SOURCE_ARCHIVE]
omen-acpi install <s5|combined|both> [BUILD_ARCHIVE]
omen-acpi status [s5|combined|all]
omen-acpi remove <s5|combined|all>
omen-acpi artifacts
omen-acpi logs
omen-acpi resume
omen-acpi reboot-stock
omen-acpi uninstall
```

`NO_COLOR`, `--no-color`, `--plain` and non-interactive help output are
supported. `--plain` disables colour, ANSI control sequences and Unicode UI
characters. Global options may appear before or after a command.

The numbered scripts under `scripts/` are private implementation engines and do
not need to be invoked manually.

## Normal entry versus experimental entry

After installation your bootloader menu contains the entries it had before, plus
one reserved entry per installed variant:

| Entry | What it boots |
| --- | --- |
| your normal CachyOS entry | stock firmware DSDT, unchanged |
| `zz-omen-acpi-s5-test` | same kernel snapshot, with the `s5` DSDT override |
| `zz-omen-acpi-combined-test` | same kernel snapshot, with the `combined` DSDT override |

The experimental entries are additions. The normal entry is never replaced,
reordered or made non-default, and the toolkit never changes which entry is
default. **You select an experimental entry manually, every time.**

## Verifying

After rebooting into an experimental entry:

```bash
omen-acpi status all
```

Status compares the active DSDT with the managed AML, checks entry and state
integrity, and detects stale kernel/initramfs snapshots. Combined managed status
also reports relevant `AE_AML_BUFFER_LIMIT`, `WQBZ` or `WQBE` messages.

For a shutdown test, save all work, disconnect external displays and preferably
the AC adapter, then use the normal desktop shutdown action or:

```bash
sync && systemctl poweroff
```

Leave the laptop on a hard surface and confirm that it cools completely. A
useful stress case is to use the NVIDIA GPU immediately before shutdown and
compare powered-off battery loss across several repetitions.

## Returning to the stock entry

Select your normal CachyOS entry in the bootloader menu. Nothing else is needed:
the override exists only in the experimental entries' initramfs.

The original source must be collected while no ACPI override is active. The CLI
does not infer this from the DSDT revision alone. It combines the active DSDT
header, declared length, checksum, OEM identity, revision and SHA-256
fingerprint; exact comparison with any managed AML; current-boot kernel messages
indicating an ACPI table upgrade or override; the Linux ACPI-override taint bit;
and the private stock fingerprint saved after the first clean collection.

If the result is inconsistent or cannot be verified, collection and installation
fail closed, and the CLI shows a guided blocker naming the exact entry to select.
It can reboot after confirmation, but it never changes the default entry.

If the system is already running the clean stock DSDT, `omen-acpi reboot-stock`
reports success without requiring unrelated build dependencies or another
reboot.

## Removal

To remove a variant:

```bash
omen-acpi remove s5
```

```bash
omen-acpi remove combined
```

Removal touches only the selected managed entry, drop-in and root state. It does
not change the BIOS DSDT or the other variant. Removing the currently active
variant does not unload its DSDT from the running kernel; reboot into the normal
entry before collecting a new source.

To remove the program itself, first remove both managed variants, then:

```bash
omen-acpi uninstall
```

The uninstaller refuses to orphan managed Limine entries and preserves private
user artifacts.

## Updating

Running `sudo ./install.sh` over an existing installation updates only the
program, command and documentation. **It does not rewrite `/var/lib` state,
Limine entries, command-line drop-ins or the EFI system partition.**

The separately distributed `update.sh` is reusable. Keep it together with a
release archive and its adjacent `.sha256` file, then launch it as your normal
user. On first use it installs an `omen-acpi-update` command under
`~/.local/bin`; later releases can be installed by downloading only the new
archive and checksum and running that command. The updater picks the highest
complete `X.Y.Z` release found in the current working directory, beside
`update.sh`, or in the user's Downloads directory, verifies both checksum
layers, blocks downgrades and invokes the transactional installer.

To verify a release without installing anything:

```bash
./update.sh --verify-only
```

If only some of the three installed paths are present, the installation is
partial. The updater detects this and passes `--repair` to the installer, which
rebuilds all three transactionally from the verified release. The same repair
can be requested manually with `sudo ./install.sh --repair`.

### Recreate entries after system updates

Each managed test entry contains a snapshot of the normal kernel and initramfs
that existed when it was created. After every kernel, initramfs or Limine
update, recreate the experimental entries instead of updating them in place:

```bash
omen-acpi remove all
```

```bash
omen-acpi install both
```

A fresh installation reuses the verified ACPI transformation but copies the
current normal kernel, initramfs modules and command line. This avoids booting a
stale payload after a system update.

## Entry lifecycle

The lifecycle is intentionally limited to two state-changing operations: install
a fresh entry from the current normal CachyOS kernel and initramfs, and remove
an installed entry after exact ownership checks.

There is no migration, old-payload restoration or in-place refresh. Those paths
can accidentally retain a kernel or initramfs from before a system update. A
recognised legacy entry is displayed as `LEGACY / REINSTALL`: remove it from the
normal CachyOS boot, then create a fresh managed entry. Modified, partial or
mixed state is displayed as `CONFLICT / BLOCKED` and is never changed
automatically.

## Dependencies

The CLI checks commands rather than assuming that packages are present, and uses
an operation-specific dependency profile. Stock-boot recovery, status and
removal therefore do not require the ACPI compiler or build toolchain. On
CachyOS/Arch Linux it maps missing commands to these packages:

| Package | Main required commands |
| --- | --- |
| `acpica` | `acpidump`, `acpixtract`, `iasl` |
| `cpio` | `cpio` |
| `mkinitcpio` | `lsinitcpio` |
| `util-linux` | `findmnt`, `flock`, `dmesg` |
| `python` | `python3` |
| `limine-entry-tool` | `limine-entry-tool` |
| `diffutils`, `findutils`, `grep`, `gzip`, `gawk`, `tar`, `sed` | build and validation tools |
| `coreutils`, `sudo`, `systemd` | base management tools |

Before installing anything, the CLI runs `pacman -Qu` against the configured
sync databases. If upgrades are pending, it blocks a partial upgrade and asks
for separate confirmation before running `sudo pacman -Syu`. It then installs
only the missing packages with `sudo pacman -S --needed`. It never runs
`pacman -Sy`, never removes Pacman's lock and never silently performs a full
system upgrade. `--yes` does not auto-confirm `pacman -Syu`, a reboot, removal
or uninstall. If `limine-entry-tool` is unavailable in the configured
repositories, automatic installation stops with guidance rather than invoking an
AUR helper.

## Private artifacts and logs

Generated source archives, build archives and operation logs are stored under:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/omen-acpi-fix/
```

The directories use mode `0700` and generated files use mode `0600`. The
collector excludes raw `acpidump` output, unrelated ACPI tables, system logs,
kernel command line, hostname, serial numbers and GPU identifiers from its
archive. Decompiled firmware is still machine-derived data: treat every source
or build archive as **private by default** and review it manually before
sharing.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| An experimental entry does not boot | Select the normal CachyOS entry in the bootloader menu, then `omen-acpi remove <variant>`. |
| `BLOCKED: an ACPI override is active in this boot` | You are booted into an experimental entry. Reboot into the normal entry before collecting or installing. |
| Status reports `CONFLICT / BLOCKED` | State was modified outside the toolkit. Nothing is changed automatically; remove the entry from a stock boot and install a fresh one. |
| Status reports `LEGACY / REINSTALL` | Remove the entry, then install a fresh managed one. |
| Status reports a stale kernel/initramfs snapshot | A system update happened. Run `omen-acpi remove all` then `omen-acpi install both`. |
| `omen-acpi` not found after an update | Refresh your shell's command cache: `hash -r` in Bash, `rehash` in Zsh. Fish needs nothing. |
| The updater says a release is "already installed and consistent" | That version is current. Use `--force` only if you intentionally need to reinstall it. |

## Known limits

- One hardware, board and BIOS combination. Nothing else is supported or tested.
- The shutdown correction depends on the discrete GPU being in a state the
  firmware considers powered; the firmware's own power resource declines to act
  otherwise.
- The `combined` variant's WQBZ bounds fix has been observed to remove the
  reported error on the reference machine but is not independently
  regression-tested across firmware revisions.
- Secure Boot is not supported: the toolkit signs nothing.
- Experimental entries embed a kernel/initramfs snapshot and must be recreated
  after system updates.
- A BIOS update invalidates every assumption in this repository.

## Safety and disclaimer

**This project is experimental and modifies ACPI behaviour during boot.**

It creates custom initramfs images containing a replacement DSDT and adds
separate experimental Limine entries. A firmware, kernel or bootloader mismatch
can cause a failed boot, data loss, system instability, abnormal thermal
behaviour, battery drain while the machine is powered off, or the need to
recover the system manually. An incorrect DSDT can prevent Linux from booting.

Before using it, understand and accept the following.

- The project is intended **exclusively** for the hardware and BIOS revision
  stated in [Supported hardware](#supported-hardware). Do not use it on a
  different model, board revision or BIOS version.
- Secure Boot must be disabled, as documented above. The toolkit signs nothing
  and does not work around Secure Boot.
- **Always keep a working stock boot entry available.** The toolkit does not
  remove or modify it, and you must not remove it yourself.
- **Never make an experimental entry the default** before repeated successful
  testing.
- You must know how to select the normal entry in the bootloader menu and how to
  remove an override before you install one.
- Save all work before testing shutdown.
- Use is entirely at your own risk.

This software is provided **without any warranty**, to the extent permitted by
applicable law, under the terms of the GNU General Public License version 3. See
sections 15, 16 and 17 of [`LICENSE`](LICENSE) for the full disclaimer of
warranty and limitation of liability.

To the maximum extent permitted by applicable law, the author and contributors
shall not be liable for any direct, indirect, incidental, special or
consequential damages, including but not limited to data loss, boot failure,
hardware damage or any other effect arising from the use of this software.

This section is **not** a licence and adds no terms to the GPL. It is a plain
summary of risk. The licence is [`LICENSE`](LICENSE) and nothing else.

This project is not affiliated with, endorsed by or supported by HP, NVIDIA,
AMD, Arch Linux, CachyOS or the Limine project. Product names and trademarks
belong to their respective owners.

## Repository layout

```text
omen-acpi                 public interactive and command-line frontend
install.sh                checksum-verifying /usr/local installer
uninstall.sh              guarded uninstaller
update.sh                 reusable release updater (separate release asset)
scripts/                  private audited engines used by the frontend
patches/README.md         normalized S5 and WQBZ transformations
tests/                    synthetic, non-firmware regression tests
docs/                     firmware analysis notes and the audit tool
README.md
CHANGELOG.md
LICENSE
SHA256SUMS
```

`update.sh` and `docs/` are part of the repository but are **not** part of the
release archive: the archive contains exactly the files covered by `SHA256SUMS`.

No ACPI dump, decompiled or compiled firmware table, initramfs, Limine
configuration, machine serial number, UUID or Windows OEM key is distributed by
this repository.

## Firmware analysis notes

[`docs/nvde-analysis.md`](docs/nvde-analysis.md) records a separate
audit of the `NVDE` namespace variable and its relationship to the firmware's
GPU power-down path, together with the tool used to produce it,
[`docs/nvde-audit.py`](docs/nvde-audit.py).

These notes are **background research, not a description of what the toolkit
guarantees.** They document what is provable from the AML, what was measured on
the reference machine, and what remains dependent on the behaviour of the
proprietary NVIDIA driver. The shipped variants are unaffected by them: neither
writes `NVDE`.

## Project status

Stable for its single intended target, and experimental by nature. It is a
reproduction for one confirmed hardware and firmware combination, not a
universal compatibility claim.

## Upstream references

- [Linux initrd ACPI table override documentation](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html)
- [CachyOS boot manager and Limine configuration](https://wiki.cachyos.org/configuration/boot_manager_configuration/)
- [Arch Linux Pacman manual](https://man.archlinux.org/man/pacman.8.en)

## License

Copyright (C) 2026 Paolo De Marinis

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [`LICENSE`](LICENSE) for the full text.

Firmware tables extracted locally by the toolkit remain subject to their
respective rights and are not distributed by this repository.
