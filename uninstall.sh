#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

readonly TARGET_ROOT="/usr/local/lib/omen-acpi-fix"
readonly TARGET_BIN="/usr/local/bin/omen-acpi"
readonly TARGET_DOC="/usr/local/share/doc/omen-acpi-fix"
readonly MANAGER="$TARGET_ROOT/scripts/03-manage-limine-entry.sh"

removed_root=''
removed_bin=''
removed_doc=''
root_moved=0
bin_moved=0
doc_moved=0
removal_started=0
removal_committed=0
hook_transaction=''
hooks_prepared=0
preserve_hook_transaction=0

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

rollback_removal() {
    (( removal_started )) || return 0
    warn "Uninstall failed; restoring the installed toolkit paths."

    if (( root_moved )); then
        if ! path_exists "$TARGET_ROOT" && path_exists "$removed_root"; then
            mv -T -- "$removed_root" "$TARGET_ROOT" \
                || warn "Could not restore the program directory from: $removed_root"
        else
            warn "Program recovery directory remains at: $removed_root"
        fi
    fi
    if (( doc_moved )); then
        if ! path_exists "$TARGET_DOC" && path_exists "$removed_doc"; then
            mv -T -- "$removed_doc" "$TARGET_DOC" \
                || warn "Could not restore the documentation from: $removed_doc"
        else
            warn "Documentation recovery directory remains at: $removed_doc"
        fi
    fi
    if (( bin_moved )); then
        if ! path_exists "$TARGET_BIN" && path_exists "$removed_bin"; then
            mv -T -- "$removed_bin" "$TARGET_BIN" \
                || warn "Could not restore the public command from: $removed_bin"
        else
            warn "Public-command recovery file remains at: $removed_bin"
        fi
    fi
    if (( hooks_prepared )); then
        local helper="$TARGET_ROOT/scripts/07-maintenance.py"
        [[ -f "$helper" && ! -L "$helper" ]] || helper="$removed_root/scripts/07-maintenance.py"
        if [[ -f "$helper" && ! -L "$helper" ]]; then
            python3 "$helper" rollback --transaction "$hook_transaction" \
            || { preserve_hook_transaction=1; warn "Hook rollback needs attention; transaction retained at $hook_transaction"; }
        else
            preserve_hook_transaction=1
            warn "Hook rollback helper is unavailable; transaction retained at $hook_transaction"
        fi
    fi
    removal_started=0
}

on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if (( rc != 0 && ! removal_committed )); then
        rollback_removal
    fi
    if (( ! preserve_hook_transaction )) && [[ -n "$hook_transaction" && "$hook_transaction" == /var/tmp/omen-acpi-hooks.* ]]; then
        rm -rf -- "$hook_transaction"
    fi
    exit "$rc"
}

if (($# > 0)); then
    case "$1" in
        -h|--help)
            printf 'Usage: uninstall.sh\n'
            printf 'Remove the installed toolkit after all managed Limine entries are removed.\n'
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
fi

for command in python3 id mktemp cmp flock install mv realpath rm stat; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

if (( EUID != 0 )); then
    [[ -x /usr/bin/sudo ]] || die "sudo is required to uninstall the toolkit."
    exec /usr/bin/sudo -- "$(realpath -- "$0")" "$@"
fi

for state in /var/lib/omen-acpi-s5-test /var/lib/omen-acpi-combined-test /var/lib/omen-acpi-s5-vfio-test /var/lib/omen-acpi-stock-recovery; do
    [[ ! -e "$state" && ! -L "$state" ]] \
        || die "Managed state still exists at $state. Remove it with omen-acpi first; stock recovery is never deleted implicitly."
done
for dropin in \
    /etc/limine-entry-tool.d/90-omen-acpi-s5-test.conf \
    /etc/limine-entry-tool.d/91-omen-acpi-combined-test.conf \
    /etc/limine-entry-tool.d/92-omen-acpi-s5-vfio-test.conf; do
    [[ ! -e "$dropin" && ! -L "$dropin" ]] \
        || die "Managed Limine drop-in still exists at $dropin. Remove it through omen-acpi first."
done

existing_targets=0
for target in "$TARGET_ROOT" "$TARGET_BIN" "$TARGET_DOC"; do
    if path_exists "$target"; then
        ((existing_targets += 1))
    fi
done

if (( existing_targets == 0 )); then
    printf 'OMEN ACPI Toolkit is not installed.\n'
    exit 0
fi
(( existing_targets == 3 )) \
    || die "A partial or conflicting toolkit installation exists; refusing automatic deletion. Rebuild it first with 'omen-acpi-update' or 'sudo ./install.sh --repair', then uninstall again."

[[ -d "$TARGET_ROOT" && ! -L "$TARGET_ROOT" ]] \
    || die "Install root is not a normal directory: $TARGET_ROOT"
[[ -f "$TARGET_BIN" && ! -L "$TARGET_BIN" ]] \
    || die "The public command path is not a normal file: $TARGET_BIN"
[[ -d "$TARGET_DOC" && ! -L "$TARGET_DOC" ]] \
    || die "Documentation path is not a normal directory: $TARGET_DOC"
[[ "$(stat -c '%u' -- "$TARGET_ROOT")" == "0" \
    && "$(stat -c '%u' -- "$TARGET_BIN")" == "0" \
    && "$(stat -c '%u' -- "$TARGET_DOC")" == "0" ]] \
    || die "Installed toolkit targets are not all owned by root."
[[ -f "$TARGET_ROOT/omen-acpi" && ! -L "$TARGET_ROOT/omen-acpi" ]] \
    || die "The installed reference executable is missing."
cmp -s -- "$TARGET_BIN" "$TARGET_ROOT/omen-acpi" \
    || die "The public command was modified; refusing to delete it automatically."
[[ -f "$MANAGER" && ! -L "$MANAGER" && -x "$MANAGER" ]] \
    || die "The installed manager is missing or unsafe: $MANAGER"

# shellcheck source=scripts/08-locks.sh
[[ -f "$TARGET_ROOT/scripts/08-locks.sh" && ! -L "$TARGET_ROOT/scripts/08-locks.sh" ]] \
    || die "Shared lock helper is missing; repair the installation before uninstalling."
source "$TARGET_ROOT/scripts/08-locks.sh"
omen_acpi_acquire_locks || die "Could not acquire the shared boot/toolkit locks."
export OMEN_ACPI_INTERNAL_OPERATION=1
# Check again under the locks so a concurrent install cannot escape preflight.
for state in /var/lib/omen-acpi-{s5,combined,s5-vfio}-test /var/lib/omen-acpi-stock-recovery; do
    [[ ! -e "$state" && ! -L "$state" ]] || die "Managed state still exists at $state."
done

# The uninstaller already owns descriptor 9 for the shared toolkit lock. The
# manager validates and reuses that inherited descriptor, locates the mounted
# ESP with its normal fail-closed parser, and proves that neither reserved entry
# name remains before any toolkit path is detached.
OMEN_ACPI_LOCK_FD9_HELD=1 "$MANAGER" pre-uninstall-check

hook_transaction="$(mktemp -d /var/tmp/omen-acpi-hooks.XXXXXX)"
trap on_exit EXIT
python3 "$TARGET_ROOT/scripts/07-maintenance.py" prepare --source "$TARGET_ROOT" \
    --previous "$TARGET_ROOT" --transaction "$hook_transaction" --remove
hooks_prepared=1

transaction_token="$$"
removed_root="/usr/local/lib/.omen-acpi-fix.removed.$transaction_token"
removed_bin="/usr/local/bin/.omen-acpi.removed.$transaction_token"
removed_doc="/usr/local/share/doc/.omen-acpi-fix.removed.$transaction_token"
for removed_path in "$removed_root" "$removed_bin" "$removed_doc"; do
    ! path_exists "$removed_path" \
        || die "Unexpected uninstall recovery path already exists: $removed_path"
done

trap on_exit EXIT
removal_started=1
python3 "$TARGET_ROOT/scripts/07-maintenance.py" apply --transaction "$hook_transaction"

bin_moved=1
mv -T -- "$TARGET_BIN" "$removed_bin"
doc_moved=1
mv -T -- "$TARGET_DOC" "$removed_doc"
root_moved=1
mv -T -- "$TARGET_ROOT" "$removed_root"
removal_committed=1
rm -rf -- "$hook_transaction"
hook_transaction=''
trap - EXIT

cleanup_failed=0
if ! rm -f -- "$removed_bin"; then
    warn "Could not delete detached public command: $removed_bin"
    cleanup_failed=1
fi
if ! rm -rf -- "$removed_doc"; then
    warn "Could not delete detached documentation: $removed_doc"
    cleanup_failed=1
fi
if ! rm -rf -- "$removed_root"; then
    warn "Could not delete detached program directory: $removed_root"
    cleanup_failed=1
fi

(( cleanup_failed == 0 )) \
    || die "Toolkit paths were detached, but one or more recovery paths could not be deleted."

printf 'OMEN ACPI Toolkit was removed.\n'
printf 'Private source/build archives in the user data directory were preserved.\n'
