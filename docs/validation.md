# Validation record

Copyright (C) 2026 Paolo De Marinis
SPDX-License-Identifier: GPL-3.0-or-later

This is the living validation record for the current state of `main`. It is not
a general hardware-compatibility claim. Each Git tag preserves the historical
record shipped with that Release.

## Validation scope

Real-hardware validation is limited to one reference laptop and the observations
recorded on 4 and 9 August 2026. Automated fixtures exercise destructive,
corrupt and concurrent states without reproducing them on the physical machine.
An absent test on other hardware means **not validated**, not expected to work.

The v2.5.0, v2.4.0 and v2.3.0 reference-machine transformations and AML
round-trip verifiers are byte-identical; the generated S5-only and Combined AML
remains byte-identical to v2.1.11 from the same stock DSDT. Real-hardware boot
and shutdown results were established with v2.1.11 and the standard/LTS
lifecycle with v2.3.0. Version 2.5.0 changes Limine titles, comments,
stock-preservation checks and kernel-update refresh automation without changing
those executable ACPI paths, so no new physical validation was required.

## Reference hardware

| Property | Validated value |
| --- | --- |
| Retail model | HP OMEN MAX 16-ap0006sl |
| DMI product | `OMEN Gaming Laptop 16-ap0xxx` |
| Mainboard | `8E35` |
| BIOS | `F.13` |
| Distribution | CachyOS |
| Validated baseline kernel | `7.1.5-1-cachyos` |
| v2.3.0 installed kernels | `7.1.6-1-cachyos`; `6.18.42-1-cachyos-lts` |
| v2.3.0 running kernel | `6.18.42-1-cachyos-lts` |
| NVIDIA GPU | NVIDIA GeForce RTX 5070 Laptop GPU (`GB206M`, `10de:2d18`) |
| Validated baseline NVIDIA driver | NVIDIA Open Kernel Module `610.43.03` (`linux-cachyos-nvidia-open 7.1.5-1`, `nvidia-utils 610.43.03-1`) |
| v2.3.0 NVIDIA packages | `linux-cachyos-nvidia-open 7.1.6-1`; `linux-cachyos-lts-nvidia-open 6.18.42-1`; `nvidia-utils 610.57.04-1` |
| ESP | `/boot` |
| Secure Boot | disabled |
| Normal Limine entries | `linux-cachyos`; `linux-cachyos-lts` |

The DMI product is shared by the `16-ap0xxx` family and does not establish
compatibility with any other SKU.

## Real-hardware validation

| Area | Method | Result | Limit |
| --- | --- | --- | --- |
| Stock boot detection | Real hardware | **PASS** — DSDT `0x01072009`, classified `STOCK / SAFE` with coherent stock signals | Reference machine only |
| Preventive snapshot | Real hardware | **PASS** — a 2.1.11 snapshot was created from a clean stock boot, classified `valid`, with verified stock provenance, saved kernel and initramfs, and normal entry `available` | The normal entry remained present |
| S5-only | Real hardware | **PASS** — managed entry installed and intact; DSDT `0x0107200A` booted and its active hash matched the managed S5 AML; kernel and initramfs were `CURRENT` | One boot/shutdown path on the reference machine |
| S5-only shutdown and return | Real hardware | **PASS** — shutdown completed without abnormal post-shutdown heating; the subsequent stock-entry boot succeeded | Verified shutdown observation only |
| Combined | Real hardware | **PASS** — managed entry installed and intact; DSDT `0x0107200B` booted and its active hash matched the managed Combined AML; kernel and initramfs were `CURRENT` | One boot/shutdown path on the reference machine |
| Multi-kernel Limine lifecycle | Real hardware | **PASS** — S5-only and Combined each reported exact `current` entries for both `linux-cachyos` and `linux-cachyos-lts`; stock recovery remained `valid` | Configuration/status validation; not four separate boot tests |
| Combined on LTS | Real hardware | **PASS** — running kernel `6.18.42-1-cachyos-lts`; active DSDT `0x0107200B` hash exactly matched the managed Combined AML | One active boot; S5 on LTS was not boot-tested |
| BF01/WQBZ | Real hardware | **PASS** — the verified Combined boot passed the BF01/WQBZ check, with no related `AE_AML_BUFFER_LIMIT`, `WQBZ` or `WQBE` message | That verified boot only |
| Combined shutdown and return | Real hardware | **PASS** — shutdown completed without abnormal post-shutdown heating; the subsequent stock-entry boot succeeded | Verified shutdown observation only |
| Normal `recover-stock` route | Real hardware | **PASS** — run from Combined; `linux-cachyos` was recognized and left unchanged, no unnecessary recovery entry was created, the correct reboot was offered, and the next stock boot succeeded | The normal entry was not deleted |
| Snapshot removal | Real hardware | **PASS** — snapshot, payload and manifest were removed from stock; status became `missing`, with no orphan or half-state; the normal entry and both variants remained available/installed | No corruption was induced |
| Snapshot recreation | Real hardware | **PASS** — recreated from stock as a final valid, trusted 2.1.11 snapshot; the normal entry remained available and no unnecessary recovery entry was created | The normal entry remained present |
| Limine configuration preservation | Real hardware | **PASS** — the SHA-256 of `limine.conf` was identical before removal, after removal and after recreation | The configuration-specific fingerprint is intentionally not published |
| Transaction cleanup | Real hardware | **PASS** — no `.limine.conf.omen-*` or `.omen-acpi-stock-recovery.*` residue remained on the ESP, and no `.omen-acpi-stock-recovery.*` residue remained under `/var/lib` | Checked after the completed operations |
| Final v2.3.0 pre-release state | Real hardware | **PASS** — snapshot `valid`; standard/LTS S5 and Combined entries `current`; Combined active on LTS; Secure Boot disabled; no conflict or modified state | Snapshot and variants intentionally retained |

No local backup path, UUID, entry-internal directory, DSDT hash, serial, raw ACPI
table or full terminal transcript is part of this record.

## Automated validation

| Area | Method | Result | Limit |
| --- | --- | --- | --- |
| Repository regression suite | Automated fixtures via `./tests/run.sh` | **PASS — automated fixture** | Synthetic filesystems and commands, not firmware |
| ACPI transformation fixtures | Automated fixtures | **PASS — automated fixture** | Confirms normalized transformations and expected revisions, not hardware behaviour |
| Recovery ownership, integrity and fail-closed paths | Automated fixtures | **PASS — automated fixture** | Includes malformed, hostile, incomplete and racing states |
| Frontend recovery status and dashboard rendering | Automated fixtures | **PASS — automated fixture** | Covers semantic snapshot parsing, plain output, Unicode rendering and fixed-width layout |
| NVDE audit tool | `./docs/nvde-audit.py --self-test` | **PASS — automated fixture** | Preserves the documented AML analysis; no hardware access |
| Release manifest, archive and updater verification | Automated build fixtures | **PASS — automated fixture** | Verifies candidate bytes and non-installing `--verify-only` behaviour |
| v2.4.0 equivalence audit | Diff review, local suite and GitHub Actions | **PASS — transformations, AML verifiers, patches and transform fixtures unchanged from v2.3.0** | No new physical hardware execution |
| v2.5.0 equivalence audit | Diff review and local suite | **PASS — transformations, AML verifiers, patches and transform fixtures unchanged from v2.4.0 / v2.3.0** | Limine titles, comments, stock-preservation checks and the ALPM hook (including DKMS / headers / `nvidia-utils` triggers) are new; no new physical hardware execution |

## Synthetic-only scenarios

The following are covered only by automated fixtures and were not executed on
physical hardware for safety:

- deletion of the normal `linux-cachyos` entry;
- an actual boot through a recreated recovery entry after loss of the normal entry;
- intentional corruption of a snapshot, manifest or payload;
- artificial file, directory or symlink collisions;
- concurrent race conditions and simultaneous `limine.conf` changes;
- concurrent kernel or initramfs deletion or replacement;
- failure injection during commit, rollback or cleanup;
- hostile or incomplete snapshots.

## Not validated

- Any different BIOS, board or physical hardware.
- Any other SKU in the `16-ap0xxx` family.
- Compatibility inferred only from the shared DMI product string.
- Any real-hardware execution of the v2.2.0 unvalidated-machine opt-in. Its
  consent, fail-closed and artifact-binding paths are synthetic-only.
- A real S5-only boot through the LTS entry, or a v2.3.0 managed boot through
  either standard-kernel entry.

Automated success cannot turn any of these items into a support or compatibility
claim.

## Release checks

Before a release is published, the project requires the complete repository
suite, Bash and Python syntax checks, NVDE self-test, strict `SHA256SUMS`
verification, reproducible archive comparison, archive-content audit and
non-installing updater verification to pass from a clean tree. Version 2.3.0
additionally required the standard/LTS status to remain current without
changing either ACPI transformation. Version 2.4.0 additionally requires its
ACPI transformers, AML verifiers, normalized patches and transformation
fixtures to remain identical to v2.3.0. Version 2.5.0 additionally requires
those same ACPI paths to remain identical to v2.4.0. Combined-on-LTS validation does not
imply S5-on-LTS validation. No non-reference hardware has been physically
validated.
