# Usage guide

This document is the extended operational reference for OMEN ACPI Toolkit
v2.3.0. Installation, the minimum safe workflow, stock return,
recovery limits and removal remain directly in the release `README.md`.

## Command reference

Run `omen-acpi` without arguments to open the interactive dashboard. The same
operations are available as explicit subcommands:

```text
omen-acpi setup [s5|combined|both]
omen-acpi doctor [--fix]
omen-acpi dependencies [--install]
omen-acpi collect
omen-acpi build <s5|combined|both> [SOURCE_ARCHIVE]
omen-acpi install <s5|combined|both> [BUILD_ARCHIVE]
omen-acpi refresh [s5|combined|all]
omen-acpi status [s5|combined|all]
omen-acpi remove <s5|combined|all>
omen-acpi artifacts
omen-acpi logs
omen-acpi resume
omen-acpi prepare-stock-recovery
omen-acpi recover-stock
omen-acpi reboot-stock
omen-acpi remove-stock-recovery
omen-acpi uninstall
omen-acpi version
```

Global options may appear before or after a command:

```text
--no-color, --plain
--yes
-h, --help
```

`NO_COLOR` and `--no-color` suppress colour. `--plain` also suppresses ANSI
control sequences and Unicode UI characters, which makes output suitable for
logs and simple parsers. `--yes` accepts routine confirmations; it never
auto-confirms a reboot, removal, uninstall, full system update or the
unvalidated-machine opt-in.

For a DMI identity different from the validated product, board or BIOS, a
transformation workflow is classified `UNVALIDATED / OPT-IN REQUIRED`. Before
dependencies, `sudo`, artifact directories, persistent locks or system writes,
the CLI shows the reference and detected values, risks and responsibility, then
asks `Proceed on this unvalidated machine? [y/N]`. Only `y` or `yes` authorizes
that process-local attempt. Non-interactive stdin, empty or unreadable DMI and
every other answer fail closed. A new invocation or post-reboot resume asks
again. Status, doctor, removal and managed stock-return/recovery paths do not
consume or require this opt-in.

Opt-in bypasses only exact DMI equality. Every v2.1.11 ACPI structure, boot,
GPU, kernel, initramfs, Limine, ownership, transaction and rollback check remains
mandatory, so many opted-in machines are intentionally rejected. Source and
build metadata record actual DMI and the local stock DSDT fingerprint; a BIOS or
machine change invalidates them. Historical v2.1.11 formats remain usable only
on the reference identity.

Do not run `sudo omen-acpi`. The frontend requests narrowly scoped
administrator access when an operation needs it. The numbered files under
`scripts/` are private engines and are not a public command interface.

Examples use Bash syntax. The displayed commands work unchanged in Fish unless
they contain shell-specific assignment or expansion syntax.

## Dashboard and guided setup

The dashboard summarizes machine identity, dependencies, active DSDT, stock
recovery and both managed variants. A typical clean initial state is:

```text
+ OMEN ACPI Toolkit v2.3.0 -----------------------------------------------+
|                                                                          |
|  Machine        8E35 / BIOS F.13       READY                             |
|  Dependencies   All commands available READY                             |
|  Current boot   0x01072009             STOCK / SAFE                      |
|  Stock recovery Preventive snapshot    VALID                             |
|  S5-only        Limine test entry      NOT INSTALLED                     |
|  Combined       S5 + WQBZ entry        NOT INSTALLED                     |
|                                                                          |
+--------------------------------------------------------------------------+
```

Guided setup performs these stages in order:

1. accepts the validated identity or obtains the explicit unvalidated opt-in;
2. finds missing dependencies and can install repository packages with Pacman;
3. classifies the currently loaded ACPI state;
4. requires a clean stock boot before collecting firmware source;
5. prepares or refreshes a verified preventive stock snapshot;
6. privately collects and fingerprints the original DSDT;
7. builds and independently verifies the requested transformation;
8. transactionally creates a separate Limine test entry for each detected
   primary `linux-cachyos` / `linux-cachyos-lts` kernel;
9. offers a reboot and names the entry the user must select.

The complete choice is displayed before confirmation:

```text
Choose the experimental setup:

  1. S5-only
     Recommended — confirmed shutdown correction

  2. Combined
     S5 correction plus the separate WQBZ bounds patch

  3. Both
     Create two independent experimental Limine entries

  b. Back

Choose an option [1 — S5-only]:
```

Enter selects S5-only. `b`, EOF or rejecting the variant-specific confirmation
returns without changing anything.

The dashboard key `r` always opens **Stock boot and recovery**. A pending setup
workflow is shown separately as `p`; its reboot-or-resume state is not replaced
by the recovery menu.

## Status and boot classification

Use the widest status view after every managed boot or relevant system update:

```bash
omen-acpi status all
```

Status compares the active DSDT with each managed AML and reports the running
kernel, every detected supported kernel, fallback presence, ordered initramfs
count, detected NVIDIA module names and each corresponding owned entry. Combined
status also reports relevant `AE_AML_BUFFER_LIMIT`, `WQBZ` and `WQBE` messages
from the current boot.

Stock source collection is more restrictive than checking an OEM revision. The
classifier combines the active DSDT header, length, checksum, OEM identity,
revision and SHA-256; exact comparison with managed AML; kernel messages that
indicate an ACPI override; the Linux ACPI-override taint bit; and the private
stock fingerprint saved after clean collection. An inconsistent or unverifiable
result blocks collection and installation.

Managed lifecycle states include:

- `CURRENT`: every detected supported kernel has the exact managed entry
  expected from its current stock Limine metadata;
- `LEGACY / REINSTALL`: ownership is recognized, but the entry must be removed
  from a normal stock boot and installed fresh;
- `CONFLICT / BLOCKED`: state is partial, mixed or externally modified and is
  never changed automatically;
- stale kernel/initramfs: run `omen-acpi refresh` before booting the owned entry.

## Entry lifecycle

Each experimental entry references the current stock kernel and ordered stock
initramfs components for exactly one kernel ID. It prepends one shared
variant-specific ACPI early CPIO. This avoids per-variant copies of the kernel,
initramfs and NVIDIA modules while keeping standard and LTS entry identity
separate.

After a kernel, initramfs or Limine update—or after installing/removing LTS—run:

```bash
omen-acpi refresh all
```

Use `s5` or `combined` instead of `all` when appropriate. Refresh verifies the
old ownership record, current stock paths and BLAKE2 hashes, initramfs contents
and the new result before committing. Repeating it makes no duplicate entries.
Recognized v2.2.0 single-kernel managed state is migrated in place using its
already verified AML; pre-managed legacy state retains its normal removal path.

Removing a currently active entry does not unload its DSDT from the running
kernel. Reboot into the normal entry before collecting a new source or testing
the freshly created entry.

The independent recovery lifecycle is prepare from a clean stock boot, recover
or verify the reserved entry, and explicit removal. Its detailed invariants are
documented in [`recovery.md`](recovery.md).

## Dependencies

Dependency checks are operation-specific. Recovery status and removal do not
require the full ACPI build toolchain. On CachyOS/Arch Linux, missing commands
map to these packages:

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

Before installing packages, the CLI runs `pacman -Qu` against configured sync
databases. Pending upgrades block a partial upgrade and require separate
confirmation before `sudo pacman -Syu`. Missing packages are installed with
`sudo pacman -S --needed` only after confirmation. The toolkit never runs
`pacman -Sy`, removes Pacman's lock or invokes an AUR helper. `--yes` does not
confirm a full upgrade.

## Program updates and repair

Running `sudo ./install.sh` over an existing installation updates the program,
public command and installed documentation. It then reconciles recognized
managed state with current standard/LTS entries. A failed reconciliation leaves
stock entries intact and reports the explicit `omen-acpi refresh` command.

The separately distributed `update.sh` is reusable. Keep it with the release
archive and adjacent `.sha256`, then run it as the normal user. On first use it
installs `omen-acpi-update` under `~/.local/bin`. It finds the highest complete
`X.Y.Z` asset set in the working directory, beside the script or in Downloads;
verifies both checksum layers; blocks downgrades; and invokes the transactional
installer.

Verify an asset set without installation:

```bash
./update.sh --verify-only
```

If only some of the three installed paths exist, the updater identifies a
partial installation and passes `--repair`. Manual repair is also available:

```bash
sudo ./install.sh --repair
```

Repair transactionally rebuilds the program paths from the verified release;
it does not repair modified variant or recovery state.

## Private artifacts and logs

Generated source archives, build archives and operation logs are stored under:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/omen-acpi-fix/
```

Directories use mode `0700` and generated files use mode `0600`. The collector
excludes raw `acpidump` output, unrelated ACPI tables, system logs, kernel
command line, hostname, serial numbers and GPU identifiers from its archive.
Decompiled firmware is still machine-derived data. Treat source and build
archives as private, and review them manually before sharing.

`omen-acpi artifacts` lists private build material. `omen-acpi logs` lists
operation logs. Neither command publishes anything.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| An experimental entry does not boot | Select the normal CachyOS entry, then run `omen-acpi remove <variant>`. |
| `BLOCKED: an ACPI override is active in this boot` | Reboot into the normal entry before collection or installation. |
| `CONFLICT / BLOCKED` | External or partial state was detected. Nothing is changed automatically; inspect it from a stock boot. |
| `LEGACY / REINSTALL` | Return to stock, remove the entry and install a fresh one. |
| Stale standard/LTS entry metadata | Run `omen-acpi refresh all` before selecting an owned entry. |
| Recovery is missing or refresh-required | Keep at least one supported stock entry, boot it cleanly and run `omen-acpi prepare-stock-recovery`. |
| Normal entry and trusted snapshot are both missing | Do not reuse a variant initramfs; use external manual recovery media. |
| Recovery manifest or payload hash fails | Nothing is changed. Restore a normal stock boot externally and prepare a fresh snapshot. |
| Only one half of the recovery pair exists | Status reports `modified`; inspect it manually. It is not repaired or deleted automatically. |
| Recovery removal says the normal entry is unusable | Restore one unambiguous normal entry whose kernel and all initramfs payloads pass validation. |
| `omen-acpi` is not found after update | Run `hash -r` in Bash or `rehash` in Zsh. Fish needs no refresh. |
| Updater reports “already installed and consistent” | The release is current. Use `--force` only for an intentional reinstall. |

## Repository layout

```text
omen-acpi                 public interactive and command-line frontend
install.sh                checksum-verifying /usr/local installer
uninstall.sh              guarded uninstaller
update.sh                 reusable release updater (separate release asset)
scripts/                  private audited engines used by the frontend
patches/README.md         normalized S5 and WQBZ transformations
tests/                    synthetic, non-firmware regression tests
docs/                     validation, analysis and extended documentation
README.md                 packaged operational and safety guide
CHANGELOG.md
LICENSE
SHA256SUMS
```

`update.sh` and `docs/` are repository files but are not included in the release
archive. The archive contains exactly the files covered by `SHA256SUMS`.
