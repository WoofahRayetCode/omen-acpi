# Changelog

## 2.1.9 - 2026-08-01

- Contained every interactive menu action in a subshell. All of them call
  `die()`, which exits the process, so any failure inside the dashboard
  terminated the whole CLI instead of returning to the menu that wraps the
  action in `|| true`. Selecting "Show last operation log" before any log
  existed was enough to drop the user out of the program.
- Stopped the interactive dashboard from offering the automatic dependency
  installation and boot-state probe when `OMEN_ACPI_TESTING=1`. On the
  reference machine those prompts consumed the smoke test's input and could
  reach `sudo` from inside the test suite.
- Made the managed status report survive an unreadable live DSDT instead of
  printing a Python traceback: the read is now attempted, not predicted.
- Added a regression test that drives the interactive menu into a failing
  action and requires the CLI to return to the dashboard.
- Relicensed the project from MIT to the GNU General Public License version 3
  or later. `LICENSE` now carries the complete, unmodified GPLv3 text, and the
  authored scripts carry `SPDX-License-Identifier: GPL-3.0-or-later` together
  with the copyright line.
- Rewrote `README.md` for public distribution: explicit supported hardware,
  what the toolkit does and does not do, installation from a release with both
  checksum layers, normal-versus-experimental entry model, verification,
  recovery, removal, troubleshooting, known limits and a dedicated
  "Safety and disclaimer" section.
- Added `docs/`, containing the `NVDE` firmware analysis and the audit tool
  used to produce it. It is background research and is explicitly separated
  from the behaviour the toolkit guarantees; neither shipped variant writes
  `NVDE`.
- Kept every ACPI transformation, entry-management path, drop-in format and
  boot-state classification of 2.1.8 unchanged. No variant was added, renamed
  or removed, and no OEM revision changed.

## 2.1.8 - 2026-07-31

- Made the separately distributed `update.sh` search the current working
  directory first. The reusable `omen-acpi-update` command lives in
  `~/.local/bin`, so it previously only looked beside itself and in
  `Scaricati`/`Downloads` and could not see an archive in the directory it was
  launched from.
- Replaced the "no release found" error with the explicit list of every
  directory that was searched.
- Added `install.sh --repair`, which rebuilds all three toolkit paths when only
  some of the program directory, the public command and the documentation are
  present. Each target is now backed up and rolled back independently, so a
  partial installation is repaired transactionally.
- Fixed the installer's `sudo` re-exec to forward its original arguments; they
  were previously consumed before the privilege escalation.
- Made `update.sh` detect a partial installation and pass `--repair` to the
  verified installer, so its "the verified release will repair the program
  installation" promise is now actually kept instead of failing closed.
- Pointed the uninstaller's partial-installation refusal at the repair path
  instead of leaving the user without a supported way forward.
- Kept every ACPI transformation, entry-management path, drop-in format and
  boot-state classification of 2.1.7 unchanged.

## 2.1.7 - 2026-07-31

- Reduced entry management to two write paths: fresh installation and verified
  removal. The public CLI and root manager no longer expose migration,
  pre-migration restoration or in-place refresh.
- Kept the freshly installed managed format, JSON command-line drop-ins and the
  v2.1.6 ACPI transformations unchanged. In particular, S5 remains the
  machine-validated `OMPR = 3` followed by `PEGP._PS3()` sequence without an
  `NVDE = 1` write.
- Changed recognised legacy state to `LEGACY / REINSTALL`. It can be removed
  safely, but it is never adopted, migrated or restored as a bootable payload.
- Replaced refresh guidance after kernel/initramfs updates with the explicit
  sequence `remove` followed by a fresh `install`, which copies the current
  normal CachyOS kernel, initramfs modules and command line.
- Removed the recovery shortcut and state-conversion commands from the
  dashboard, guided setup, resumable workflows and documented command set.
- Kept old command names as non-mutating compatibility errors that direct the
  user to remove and freshly install the selected entry.

## 2.1.6 - 2026-07-31

- Added `omen-acpi restore-legacy [s5|combined|all]` for installations migrated
  by v2.1.1 through v2.1.5. It validates the root-only recovery manifest,
  legacy state, AML, drop-in, initramfs fingerprint, Limine SHA-512 suffixes and
  unchanged normal entry before recreating the exact pre-migration payload.
- Preserved the superseded managed state under
  `/var/lib/omen-acpi-managed-recovery/` after a successful restoration and
  added transactional rollback to the previous managed entry on failure.
- Fixed managed command-line generation to use the JSON double-quoted format
  expected by `limine-entry-tool`; shell-style single quotes are no longer
  copied literally into `limine.conf`.
- Removed the added `omen_acpi.variant=` argument from new entries so their
  command line is identical to the selected normal CachyOS entry.
- Reverted the S5 transformation to the original machine-tested sequence:
  `OMPR = 3` followed by `PEGP._PS3()`. The later `NVDE = 1` addition is no
  longer generated by either independent builder.
- Disabled rebuilding migration. Exact recognised legacy entries are now shown
  as `LEGACY / PRESERVED`; migrated states with a linked backup are shown as
  `RESTORE AVAILABLE`.
- Added recovery-backup tamper tests, JSON drop-in regression coverage and
  updated both independent ASL transformation/verifier test paths.

## 2.1.5 - 2026-07-31

- Made the manager's independent AML round trip use the same legacy ASL
  disassembly dialect already verified by the public builder.
- Replaced ASL+-specific WQBZ matching with exact normalized checks for the two
  original S5 loops or the two bounded combined loops, both globally and inside
  the unique `WQBZ` method.
- Fixed action cleanup after fail-closed exits by retaining staging paths and
  preservation state outside function-local scope, eliminating the
  `preserve_candidate: unbound variable` failure.
- Added independent manager-verifier tests for both variants and cleanup-trap
  regression tests that preserve the original failure status.

## 2.1.4 - 2026-07-31

- Scoped the S5 round-trip guard check to the unique `_PTS` method instead of
  counting unrelated `Arg0 == 5` conditions across the complete firmware DSDT.
- Kept `NVDE = 1`, `OMPR = 3` and `PEGP._PS3()` globally unique and verified
  their presence and order inside `_PTS`.
- Added regression coverage for firmware containing three unrelated S5 tests,
  while retaining rejection of duplicate `_PTS` guards and critical actions.

## 2.1.3 - 2026-07-31

- Made Limine parsing hierarchy-aware so the active boot namespace is selected
  beside the unique shallowest `linux-cachyos` entry.
- Excluded historical Snapper entry copies from active S5 and combined entry
  validation, counting, migration, removal and recovery decisions.
- Fixed stock-entry discovery when `/CachyOS` is a group heading rather than a
  bootable Linux entry.
- Added a hierarchical regression fixture with deliberately malformed snapshot
  copies to prove that only current entries affect safety decisions.

## 2.1.2 - 2026-07-31

- Fixed legacy Limine-entry validation when `limine-entry-tool` emitted more
  than one informational `comment:` field.
- Kept the parser fail-closed for duplicated or ambiguous boot-critical
  fields, including protocol, kernel, command-line and module options.
- Added positive and negative regression fixtures for the exact reserved-entry
  parser used during legacy migration.

## 2.1.1 - 2026-07-31

- Added strict recognition of entries created by the original standalone S5
  and combined Limine test installers.
- The boot probe now identifies an active legacy variant only when the live
  DSDT hash matches a safe, exact legacy state; patched revision alone remains
  insufficient.
- Added explicit `managed`, `legacy`, `conflict` and `absent` installation
  formats to the dashboard and diagnostics.
- Added `omen-acpi migrate [s5|combined|all]`, including the stock-boot resume
  gate, one fresh source collection, prebuilding before mutation, a dangerous
  confirmation and root-side revalidation under the shared lock.
- Legacy migration rebuilds the current patch instead of adopting old AML
  metadata, because the old S5 sequence did not include `NVDE = 1`.
- Added root-only persistent migration recovery under
  `/var/lib/omen-acpi-legacy-backups/` and transactional restoration of the
  validated old entry if replacement fails.
- Status now reports recognised legacy entries and their active AML match
  without failing on current-schema metadata that did not exist in the old
  scripts.
- Legacy removal is available through the same public CLI and retains recovery
  material; ambiguous or modified state remains fail-closed.
- Clarified that rerunning `install.sh` updates program files only and never
  silently rewrites Limine entries or root state.
- Added legacy positive and tamper fixtures to the boot-state and manager
  regression tests.

## 2.1.0 - 2026-07-31

- Added the single public `omen-acpi` command with a styled dashboard, guided
  setup, state-aware menus and complete explicit subcommands.
- Added a checksum-verifying `/usr/local` installer and a guarded uninstaller
  that refuses to orphan managed Limine entries.
- Added command-level dependency discovery and confirmed, missing-only Pacman
  installation without partial-upgrade shortcuts.
- Added operation-specific dependency profiles so stock recovery, status and
  removal do not depend on the ACPI build toolchain.
- Added a `pacman -Qu` safety gate: pending upgrades require a separately
  confirmed `pacman -Syu` and a clean recheck before missing packages can be
  installed; `pacman -Sy` is never used.
- Added a fail-closed current-boot classifier using the active DSDT identity and
  hash, current-boot ACPI upgrade messages, the ACPI taint signal, managed AML
  hashes and per-entry command-line markers.
- Added guided stock-entry discovery, reboot confirmation and resumable pending
  workflows when an override is active.
- Pending workflows now retain the exact action and variant, distinguish the
  current boot from the next boot, and can be continued from the dashboard or
  with `omen-acpi resume`. Explicit external build archives are never silently
  substituted during resume.
- Added an interactive stock-boot recovery action; it exits successfully
  without unrelated dependency checks when a clean stock DSDT is already
  active.
- Added a private original-DSDT fingerprint and user artifact/log directories
  with restrictive permissions.
- Added defense-in-depth stock-boot gates to collection, installation and
  refresh while keeping removal available for recovery.
- Added build-result interfaces so the frontend never parses human output from
  the private engines.
- Added archive size/member limits and removed the manager's user-archive
  time-of-check/time-of-use window by copying input into private root staging.
- Added an `omen_acpi.variant=` marker to new S5 and combined Limine entries.
- Added strict early command validation, global options in either position, a
  fully ASCII `--plain` interface and an actual Secure Boot state in `doctor`.
- Guided setup now offers to refresh every already-installed selected variant
  with the newly verified build before suggesting a test reboot.
- Strengthened the independent root-side rebuild so S5-only must retain exactly
  the two original WQBZ loops, combined must replace exactly those two loops,
  and status verifies the stored managed AML against its SHA-256 checksum.
- Replaced the old three-script quick start with the guided CLI workflow.

## 2.0.0 - 2026-07-31

- Rewrote all documentation, comments and user-facing output in English.
- Removed the obsolete live custom-method and AMD-only experiments.
- Added two explicit, independently managed variants: S5-only revision
  `0x0107200A` and combined S5+WQBZ revision `0x0107200B`.
- Restored the required `NVDE = 1` operation before `OMPR = 3` and `_PS3()`.
- Kept the WQBZ/WQBE buffer-bound correction separate in meaning while making it
  available through the combined build and Limine entry.
- Minimized ACPI collection and removed diagnostic logs and raw table dumps from
  generated archives.
- Made every state-changing action explicit; running the manager without an action
  now displays help.
- Added per-variant refresh support and stale-kernel detection for system updates.
- Strengthened archive validation, build verification and rollback handling.
- Added a source license, privacy guidance and hardware-risk warnings.

## 1.0.0 - 2026-07-24

- Initial private machine-specific reproduction kit.
