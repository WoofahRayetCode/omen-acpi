# OMEN ACPI Toolkit

OMEN ACPI Toolkit is an experimental Linux tool for one incomplete-shutdown
problem observed on an HP OMEN MAX 16-ap0006sl. On that laptop, Linux could
appear to finish an S5 shutdown while the discrete NVIDIA GPU remained powered,
producing heat and drawing battery current.

The toolkit collects the laptop's own ACPI tables, builds a checked DSDT
override and adds it to a **separate Limine entry**. The normal CachyOS entries
remain available and unchanged.

> **Development model.** This repository was built through a substantially
> AI-assisted engineering workflow. OpenAI Codex produced significant portions
> of the Bash/Python implementation, automated tests and documentation. Paolo
> De Marinis supplied the hardware evidence, set objectives, safety constraints
> and acceptance criteria, reviewed targeted changes, investigated regressions,
> performed the real-hardware checks and made the release decisions.

> **This is not a generic HP OMEN fix.** Only the model, board and BIOS listed
> below have been physically validated. An incompatible ACPI override can
> prevent Linux from booting or cause instability, data loss, abnormal thermal
> behaviour or the need for manual recovery.

## What the project changes

The reference firmware exposed two separate problems:

1. its S5 preparation did not run the discrete-GPU power-down path used by the
   working override;
2. `WQBZ` could read beyond the end of buffer `BF01`, producing
   `AE_AML_BUFFER_LIMIT` messages.

They are not presented as one root cause. The toolkit provides two independent
test variants:

| Variant    | ACPI change                                                            | Use                                                                   |
| ---------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `s5`       | extends `_PTS(5)` with `PEGP.OMPR = 3` followed by `PEGP._PS3()`       | first test for the incomplete S5 shutdown                             |
| `combined` | contains the complete S5 change and separately bounds two `WQBZ` loops | test the shutdown change together with the observed buffer correction |

Both variants use the firmware's existing methods. They do not call the GPU
power resource directly, force `NVDE`, modify suspend or runtime power
management, flash the BIOS or distribute a firmware table.

## Why the S5 transformation reaches the GPU power resource

During an orderly transition to the S5 soft-off state, ACPI invokes `_PTS` with
`Arg0 == 5`. The reference firmware already contains the methods needed to turn
off the discrete GPU, but the tested stock S5 path did not enter the branch that
uses them.

The S5 transformation adds only this sequence to `_PTS(5)`:

```asl
Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)
\_SB.PCI0.GPP0.PEGP._PS3 ()
```

The order is essential. `OMPR` normally starts at `0x02`; the firmware's
`PEGP._PS3()` calls the GPU power resource only when `OMPR == 0x03`. Setting the
value first therefore opens the existing branch, and calling `_PS3()` then
reaches `PG00._OFF()`:

```text
_PTS(5) → OMPR = 3 → PEGP._PS3() → PG00._OFF()
```

`_PS3` is the device power-state method implemented by the firmware. `PG00` is
the power resource used by the discrete GPU. The transformation deliberately
does not call `PG00._OFF()` directly: it preserves the firmware's `_PS3`
sequence and its existing guards.

One of those guards is `NVDE`. `PG00._OFF()` returns without performing the
power-down body when `NVDE != 1`; it also checks the result of `GSTA()`. Neither
implemented variant writes `NVDE`. On the documented reference environment,
the NVIDIA driver was observed re-arming `NVDE` after an S3 resume, which is the
measured premise under which the minimal sequence works. That observation does
not establish the same state for another driver, BIOS or machine. The complete
DSDT/SSDT reconstruction and measurement are in
[`docs/nvde-analysis.md`](docs/nvde-analysis.md).

## Why the WQBZ change is separate

`WQBZ` is a firmware WMI query method. In the two affected loops, `BF01` is the
source buffer and `Local5` is the method-local integer used as its current
index. `Local1` indexes the destination, while `Local3` temporarily holds the
byte being copied. These names are AML local variables, not hardware registers
or error codes.

The stock loop tests the current source byte before proving that the index is
inside the buffer:

```asl
While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))
```

For a buffer of length `0x32`, the valid indices stop at `0x31`. If no zero byte
has stopped the loop before `Local5` becomes `0x32`, the condition itself tries
to read past the buffer and produces the observed `AE_AML_BUFFER_LIMIT`. The
Combined transformation first requires

```asl
Local5 < SizeOf (BF01)
```

and then performs the original zero-byte test inside the loop. It bounds exactly
two occurrences in `WQBZ`; it does not alter the S5 sequence. Conversely,
S5-only leaves both loops unchanged and was sufficient for the documented
shutdown result. The exact before/after ASL is in
[`patches/README.md`](patches/README.md).

## From the local DSDT to one experimental boot

The repository contains transformation rules, not the reference laptop's
firmware table. For each build, the toolkit follows one evidence-preserving
chain:

1. collect the DSDT currently supplied by the target machine;
2. decompile it to ASL and require the expected headers, methods and occurrence
   counts;
3. apply the selected deterministic transformation;
4. compile the result to AML, verify its header and checksum, decompile it again
   and check the reconstructed semantics;
5. place the verified AML in a small ACPI early CPIO;
6. prepend that CPIO only to a separate, owned Limine test entry.

Selecting the experimental entry makes Linux load the checked DSDT override for
that boot. Selecting a normal CachyOS entry omits the override and returns to the
firmware-supplied table. This is why the toolkit can test the transformation
without flashing the BIOS or replacing the normal entries.

## Validated reference

Physical validation is limited to this configuration:

| Property        | Value                                                    |
| --------------- | -------------------------------------------------------- |
| Retail model    | HP OMEN MAX 16-ap0006sl                                  |
| DMI product     | `OMEN Gaming Laptop 16-ap0xxx`                           |
| Mainboard       | `8E35`                                                   |
| BIOS            | `F.13`                                                   |
| Distribution    | CachyOS                                                  |
| Baseline kernel | `7.1.5-1-cachyos`                                        |
| v2.3.0 check    | standard `7.1.6-1-cachyos`; LTS `6.18.42-1-cachyos-lts`  |
| Graphics        | NVIDIA GeForce RTX 5070 Laptop GPU, hybrid firmware mode |
| ESP             | `/boot`                                                  |
| Bootloader      | Limine                                                   |
| Secure Boot     | disabled                                                 |

The DMI product name is shared by a model family. It is not evidence that
another SKU, board or BIOS is compatible.

On the reference laptop, both variants loaded the intended DSDT and completed
the tested shutdown without the previous abnormal post-shutdown heating.
Combined also completed the checked boot without the related `WQBZ`, `WQBE` or
`AE_AML_BUFFER_LIMIT` messages. The standard/LTS entry lifecycle and one
Combined LTS boot were checked with v2.3.0; S5-only on LTS was not boot-tested.

Version 2.5.0 changes Limine titles, selected-entry comments, stock-preservation
checks and kernel-update refresh automation only. Its ACPI transformers and AML
round-trip verifiers are byte-identical to v2.4.0 and v2.3.0, so the v2.3.0
hardware observations remain the applicable baseline; no broader hardware
compatibility is claimed.

The full distinction between real-hardware observations, automated fixtures and
untested cases is in [`docs/validation.md`](docs/validation.md).

## Development process

This project was developed through a substantially AI-assisted workflow using
OpenAI Codex. Codex produced significant portions of the Bash and Python
implementation, automated tests and documentation, and assisted with code review
and ACPI-analysis workflows.

Paolo De Marinis identified and reproduced the shutdown symptom, supplied the
machine observations and ACPI/log evidence, set the objectives, safety
constraints and acceptance criteria, reviewed targeted changes, investigated
regressions, performed the documented real-hardware boot, shutdown and recovery
checks, and made the release decisions.

He reviewed and accepted the agent-produced work at the relevant decision and
validation points; he does not claim an exhaustive independent line-by-line
human audit of all generated code. The repository has not received independent
review by an ACPI or systems-programming specialist, and no formal security
audit is claimed.

## Safety model

The public `omen-acpi` command runs as the normal user. It requests `sudo` only
for restricted hardware inspection, dependency installation, Limine mutation or
reboot.

Before a transformation is installed, the workflow checks:

- machine identity and readable DMI values;
- a clean stock boot and active DSDT fingerprint;
- Secure Boot, GPU, kernel, initramfs and Limine preconditions;
- exact ACPI headers, methods and occurrence counts;
- `iasl` compilation, AML header/checksum and decompile round trip;
- path type, ownership, permissions and managed-state fingerprints;
- stable files across transaction and rollback boundaries.

The toolkit creates only reserved, owned entries and state. Modified, foreign or
ambiguous state fails closed and is preserved for inspection.

It does not:

- flash or modify the BIOS;
- replace, hide, reorder or make non-default a normal CachyOS entry;
- make an experimental entry the default;
- bypass Secure Boot;
- modify suspend, S0ix or runtime GPU power management;
- install the reference machine's AML on another laptop;
- publish locally collected ACPI tables, initramfs images or machine
  identifiers.

These checks reduce accidental misapplication. They cannot make an ACPI override
risk-free.

## Unvalidated-machine opt-in

If the product, board or BIOS differs but all three DMI values are readable, a
transformation workflow stops before dependency installation, `sudo`, persistent
locks or system writes and displays the reference and detected identities. It
then asks:

```text
Proceed on this unvalidated machine? [y/N]
```

Only `y` or `yes` authorizes that invocation. The default, another answer,
non-interactive input or unreadable DMI fails closed. `--yes` does not answer
this prompt, and consent is not stored.

Opt-in bypasses only exact DMI equality. Every ACPI structure, boot-state,
build, ownership and transaction check remains active. Opt-in is not a
compatibility or support statement, and no non-reference machine has been
physically validated.

## Requirements

- CachyOS/Arch Linux with mkinitcpio and Limine;
- `linux-cachyos`, `linux-cachyos-lts`, or both, with a normal entry generated
  by the CachyOS integration;
- a kernel with `CONFIG_ACPI_TABLE_UPGRADE=y`;
- Secure Boot disabled;
- hybrid firmware graphics mode and the NVIDIA GPU at `0000:01:00.0` on the
  reference machine;
- Python 3 and the ACPI, initramfs, filesystem and checksum tools checked by the
  CLI;
- enough ESP space for one small ACPI early CPIO per installed variant and the
  optional stock-recovery copies.

The CLI can offer to install missing repository packages with Pacman. It blocks
partial system upgrades and never invokes an AUR helper.

## Installation

### Published v2.4.0 release

Use the three assets attached to the
[v2.4.0 release](https://github.com/paolo-de-marinis/omen-acpi/releases/tag/v2.4.0):

```bash
curl -LO https://github.com/paolo-de-marinis/omen-acpi/releases/download/v2.4.0/omen-acpi-toolkit-v2.4.0.tar.gz
curl -LO https://github.com/paolo-de-marinis/omen-acpi/releases/download/v2.4.0/omen-acpi-toolkit-v2.4.0.tar.gz.sha256
sha256sum -c omen-acpi-toolkit-v2.4.0.tar.gz.sha256
tar xzf omen-acpi-toolkit-v2.4.0.tar.gz
cd omen-acpi-toolkit-v2.4.0
sha256sum -c SHA256SUMS
sudo ./install.sh
omen-acpi
```

The adjacent checksum verifies the downloaded archive. The internal `SHA256SUMS`
verifies every packaged file. Both checks must pass.

### Current `main`

```bash
git clone https://github.com/paolo-de-marinis/omen-acpi.git
cd omen-acpi
sha256sum -c SHA256SUMS
sudo ./install.sh
```

Do **not** run `sudo omen-acpi`. The installed frontend must remain
unprivileged.

## Safe first run

Open the dashboard:

```bash
omen-acpi
```

Then:

1. Choose **Guided setup**.
2. Start with S5-only unless you specifically need to test the separate WQBZ
   correction.
3. Let the workflow prepare the stock snapshot, collect the local DSDT, build
   the selected variant and create the experimental entry.
4. Reboot and manually select the new entry. Never make it the default during
   initial testing.
5. Run `omen-acpi status all` and verify the active DSDT and managed entry.
6. Save all work, disconnect external displays and preferably the AC adapter,
   then shut down normally.
7. Confirm that the laptop cools completely before repeating the test.

Equivalent non-menu commands are:

```bash
omen-acpi setup s5
omen-acpi setup combined
omen-acpi setup both
omen-acpi status all
```

If setup starts from an experimental boot, the CLI records the pending action
and asks for a return to stock before continuing.

## Boot entries

The toolkit adds entries; it does not replace the normal ones.

| Entry                                                          | Purpose                                                                                 |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `linux-cachyos`                                                | normal standard-kernel entry                                                            |
| `linux-cachyos-lts`                                            | normal LTS entry, when installed                                                        |
| `linux-cachyos-fallback`, `linux-cachyos-lts-fallback`         | normal fallbacks; detected but not cloned                                               |
| `zz-OMEN ACPI S5`, `zz-OMEN ACPI S5 LTS`                       | S5-only override for standard/LTS                                                       |
| `zz-OMEN ACPI Combined`, `zz-OMEN ACPI Combined LTS`           | Combined override for standard/LTS                                                      |
| `zz-OMEN ACPI stock recovery`                                  | emergency entry created from the trusted snapshot only when the normal entry is missing |

Pre-2.5.0 titles (`zz-omen-acpi-s5-test` and the other machine-id names) remain
recognised. `omen-acpi refresh` rewrites them to the labels above. The `zz-`
prefix keeps the experimental entries after the stock `linux-cachyos*` names.

Each experimental entry reuses the stock kernel and ordered stock initramfs
paths and prepends one variant-specific ACPI early CPIO.

## Stock return and preventive recovery

To return to stock, select a normal CachyOS entry in Limine. The override exists
only in the experimental entry's initramfs.

The guided setup first creates a preventive snapshot from one unambiguous,
usable stock entry. It copies that entry's kernel and initramfs components to
reserved ESP paths and stores a root-owned manifest with their identities and
hashes.

```bash
omen-acpi prepare-stock-recovery
omen-acpi recover-stock
omen-acpi reboot-stock
omen-acpi remove-stock-recovery
```

Snapshot states include:

| State              | Meaning                                                                         |
| ------------------ | ------------------------------------------------------------------------------- |
| `valid`            | current trusted snapshot and payloads are intact                                |
| `refresh-required` | an owned older snapshot can be inspected or removed but is not trusted for boot |
| `missing`          | the snapshot pair is absent                                                     |
| `stale`            | saved payloads no longer match the usable stock source                          |
| `modified`         | ownership, type, pair or integrity checks failed                                |
| `unavailable`      | status could not be established safely                                          |

Legacy snapshots remain ownership- and integrity-checked but are never trusted
for boot. Refresh them from a clean stock boot.

`recover-stock` does not modify a configuration that still contains a usable
normal entry. If the normal entry is missing, it can create the reserved
recovery entry only from a current trusted snapshot and only after checking the
snapshot and configuration again.

This is preventive recovery, not reconstruction. If both the normal entry and a
trusted snapshot are unavailable, the toolkit cannot recreate stock kernel or
initramfs data: **external manual recovery media is required**.

The complete state and transaction rules are in
[`docs/recovery.md`](docs/recovery.md).

## Updates and removal

After a kernel, initramfs or Limine update, reconcile the owned entries:

```bash
omen-acpi refresh all
```

On CachyOS/Arch, the installer also places an ALPM hook that runs this refresh
after relevant package transactions: `linux-cachyos` / LTS (and their
NVIDIA-open and headers packages), `mkinitcpio`, Limine-related packages,
`nvidia-utils`, and any `*-dkms` / `*-dkms-git` module. That covers DKMS
installs that rebuild initramfs without upgrading the kernel package itself.
The hook never aborts pacman and never repairs modified or conflicting state;
if it reports a warning, run the command above from a stock boot.

Refresh adds a newly installed standard/LTS entry, updates changed references
and removes only obsolete owned entries. Modified or mixed state is reported as
a conflict and is not changed automatically.

`update.sh` verifies both checksum layers before calling the transactional
installer:

```bash
./update.sh --verify-only
```

Remove variants only after returning to stock:

```bash
omen-acpi remove s5
omen-acpi remove combined
omen-acpi remove all
```

To remove the installed program as well:

```bash
omen-acpi remove-stock-recovery
omen-acpi uninstall
```

The uninstaller refuses to orphan owned Limine entries or recovery state.
Private user artifacts are preserved.

## Code and tests

The shortest reading path is:

1. `omen-acpi` for the public state machine;
2. `scripts/00-probe-boot.sh` for boot classification;
3. `scripts/02-build-dsdt.sh` for the transformations;
4. `scripts/03-manage-limine-entry.sh` for privileged installation and removal;
5. `scripts/04-stock-recovery.py` and `05-kernel-entries.py` for the two larger
   state models.

[`docs/code-overview.md`](docs/code-overview.md) maps components, privileges,
writes, setup flow, state and ownership checks.

Run the synthetic suite with:

```bash
./tests/run.sh
```

It checks syntax, embedded Python, CLI behavior, transformation fixtures, opt-in
boundaries, recovery transactions, standard/LTS reconciliation, release
reproducibility and updater verification. These fixtures do not reproduce
firmware behavior or validate another machine.

## Documentation

- [`docs/code-overview.md`](docs/code-overview.md): program structure and
  reading path.
- [`docs/usage.md`](docs/usage.md): complete command reference, artifacts and
  troubleshooting.
- [`docs/recovery.md`](docs/recovery.md): snapshot states, transactions and
  limits.
- [`patches/README.md`](patches/README.md): exact normalized ACPI changes.
- [`docs/nvde-analysis.md`](docs/nvde-analysis.md): why the S5 path depends on
  the observed `NVDE` state.
- [`docs/references.md`](docs/references.md): standards, reports and prior art.
- [`docs/validation.md`](docs/validation.md): hardware observations and
  synthetic-test boundary.

Repository-only documentation is not included in the packaged release archive.
This README retains the installation, stock-return, recovery-limit and removal
information required to operate the packaged toolkit.

## Risks and limits

- Only the listed HP OMEN MAX 16-ap0006sl, board `8E35`, BIOS `F.13` has been
  physically validated.
- Opt-in on another readable DMI identity is unsupported and does not imply
  compatibility.
- Secure Boot must remain disabled.
- Keep a working normal entry and know how to select it.
- Never make an experimental entry the default before repeated successful tests.
- A BIOS update invalidates the firmware assumptions and managed identity.
- Combined has not been regression-tested across other firmware revisions.
- Recovery works only if a trusted snapshot was prepared before the normal entry
  was lost.
- Use is entirely at your own risk.

Generated firmware-derived archives are private by default. Do not publish them
without reviewing their contents. This repository contains no ACPI dump,
compiled machine table, initramfs, Limine configuration, serial number, UUID or
OEM key.

## License and affiliation

Copyright (C) 2026 Paolo De Marinis

The project is licensed under the GNU General Public License version 3 or later
and is provided without warranty. See [`LICENSE`](LICENSE).

It is not affiliated with, endorsed by or supported by HP, NVIDIA, AMD, Arch
Linux, CachyOS or the Limine project. Product names and trademarks belong to
their respective owners.