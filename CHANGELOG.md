# Changelog

## 2.1.11 - 2026-08-03

- Stock-recovery preparation now inspects every initramfs with `lsinitcpio`,
  rejects any `kernel/firmware/acpi/` content and rejects payloads whose hashes
  match a managed variant even when they have been renamed like a normal image.
- Stock-recovery removal now accepts only no reserved entry or one byte-exact
  manifest-owned entry. Missing, incomplete or duplicate markers, foreign or
  duplicate reserved entries, and one-field modifications fail without writes.
- Snapshot refresh commits the complete verified payload/manifest pair before
  non-essential cleanup. Cleanup failures preserve the new valid snapshot,
  retain safely named old backups and emit precise warnings.
- Recovery removal separates configuration replacement, state detachment,
  commit and cleanup so failures cannot produce a valid-looking half-state.
- Recovery creation and removal retain the exact initially read `limine.conf`
  bytes and verify identity, content and metadata again after backup and just
  before replacement, preventing detected concurrent changes from being lost.
- Variant installation now checks for managed, legacy or conflicting state
  before it creates or refreshes the preventive stock-recovery snapshot.
- `--plain` setup-menu output is fully ASCII and ANSI-free, including the path
  exercised by the interactive regression suite.
- `update.sh --verify-only` completes archive verification before updater
  persistence and does not create `~/.local/bin` or invoke the installer.
- Release construction, updater verification and consistency tests now include
  the Python stock-recovery manager's `2.1.11` version declaration.
- Pinned actions/checkout v7.0.1 to its full official commit SHA, retained
  read-only workflow permissions and added private security-reporting guidance.
- Treats structurally intact 2.1.10 recovery snapshots as
  `refresh-required`, never as boot-trusted: they may be ownership-checked for
  safe refresh/removal but cannot create or validate a recovery boot entry.
- Recovery snapshot removal now always requires one unambiguous, structurally
  valid normal `linux-cachyos` entry, even when no experimental variants exist.
- Added `lsinitcpio` to the stock-recovery dependency profile used by the
  standalone preparation command.
- Snapshot preparation now treats the ESP payload and `/var/lib` manifest as a
  symmetric pair. Orphaned, symlinked, wrongly typed or otherwise unverifiable
  paths are reported as `modified` and are never staged over, renamed or
  deleted automatically.
- Recovery removal now reuses the full normal-source validator: the kernel and
  every initramfs must be canonical, regular, single-linked, stable and present;
  initramfs content and managed-variant hashes are checked again immediately
  before commit. Removal remains available after a BIOS change or from an
  experimental boot when that independently verified stock route exists.
- The interactive 2.1.10 `refresh-required` path now preserves the legacy
  snapshot and reaches the explicitly confirmed normal-entry reboot when that
  entry is usable; missing, ambiguous or unusable normal state still requires
  external recovery media.
- Pre-uninstall checks now detect the reserved recovery payload on the ESP even
  when its `/var/lib` state is absent, and never delete such an orphan.
- Snapshot copies are now cryptographically bound to the initially validated
  source identities and hashes. The actual staged initramfs bytes are inspected
  with `lsinitcpio`, checked against managed variants and revalidated with the
  complete normal configuration before activation.
- Prepare, recover and remove reload the same owned or trusted snapshot at each
  mutation boundary. Transaction destinations use atomic no-replace renames;
  state that appears or changes during staging is preserved and blocks commit.
- Recovery-entry creation now rechecks the exact original `limine.conf` bytes
  immediately after the final trusted-snapshot review, then verifies both the
  installed configuration and snapshot again before discarding its backup.
- Recovery removal keeps the normal kernel and every initramfs content-checked
  across snapshot review, configuration replacement and snapshot detachment.
  Any source loss or mutation restores owned state and conditionally rolls back
  only configuration bytes still installed by the transaction.
- Configuration stage and backup files are created exclusively. Concurrent
  files, directories and valid or broken symlinks are never truncated,
  followed, replaced or removed by transaction cleanup.
- A missing snapshot is recommended for creation only when both the active boot
  and the fully validated normal source are suitable. Missing, ambiguous or
  unusable normal entries now receive fail-closed restoration guidance.
- Replaced the repository-only 2.1.11 manual-validation document with the
  explicitly unexecuted `docs/validation-plan-v2.1.11.md`; the obsolete 2.1.10
  plan remains available from its historical tag but is no longer on `main`.
- Hardware checks remain restricted to the documented reference configuration.
  Broader hardware support remains future design work and is not available.

## 2.1.10 - 2026-08-03

- Fixed Guided setup so its complete variant menu is printed directly to the
  terminal instead of being captured by command substitution. The selected
  value now travels through an explicit result variable and can only be `s5`,
  `combined` or `both`, with no interface text mixed into it.
- Moved setup confirmation after selection and made it name S5-only, Combined
  or Both. Back, EOF, invalid input and rejection all return without partial
  changes.
- Replaced the overloaded `Stock-boot recovery` action with a dedicated
  `Stock boot and recovery` submenu for snapshot creation/refresh, stock
  recovery/reboot, read-only detailed status and protected removal.
- Separated pending workflows onto the contextual `p` menu key; `r` now always
  opens recovery regardless of pending state.
- Added a real preventive stock-boot snapshot. On a clean verified stock boot,
  the toolkit records provenance and a strict JSON manifest under
  `/var/lib/omen-acpi-stock-recovery` and copies the stock kernel plus every
  ordered initramfs component to `boot():/omen-acpi-stock-recovery/`.
- Added `prepare-stock-recovery`, `recover-stock` and
  `remove-stock-recovery`, while keeping `reboot-stock` limited to rebooting
  toward an already existing normal entry.
- Added the reserved `zz-omen-acpi-stock-recovery` entry for the case where the
  normal entry was deleted. It points only at verified reserved copies,
  contains no ACPI override and never changes Limine's default or other
  entries.
- Added transactional staging, stable-source/TOCTOU checks, deterministic
  payload names, SHA-256 verification, strict ownership and permission checks,
  atomic configuration replacement and rollback.
- Added snapshot-bound `STOCK RECOVERY ACTIVE` detection that also requires a
  clean stock DSDT; a marker cannot mask S5, Combined or unknown ACPI state.
- Documented the upgrade boundary: 2.1.9 only found an existing normal entry.
  If neither that entry nor a snapshot prepared by 2.1.10 exists, automatic
  recovery is impossible and external manual recovery is required.
- Added synthetic recovery fixtures covering preparation gates, parser
  ambiguity, payload ordering and fidelity, tamper detection, safe Limine
  editing, rollback, idempotence, removal guards and recovery recognition.
- The v2.1.10 Release contains exactly the toolkit tarball, its external
  SHA-256 file and the executable `update.sh` updater.

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
