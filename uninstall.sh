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
readonly LOCK_DIRECTORY="/run/omen-acpi-fix"
readonly LOCK_FILE="$LOCK_DIRECTORY/manager.lock"

removed_root=''
removed_bin=''
removed_doc=''
root_moved=0
bin_moved=0
doc_moved=0
removal_started=0
removal_committed=0

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
    removal_started=0
}

on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if (( rc != 0 && ! removal_committed )); then
        rollback_removal
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

for command in cmp flock install mv realpath rm stat; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

if (( EUID != 0 )); then
    [[ -x /usr/bin/sudo ]] || die "sudo is required to uninstall the toolkit."
    exec /usr/bin/sudo -- "$(realpath -- "$0")" "$@"
fi

[[ -d /run && ! -L /run && "$(stat -c '%u' -- /run)" == "0" ]] \
    || die "The runtime directory is unavailable or unsafe: /run"
runtime_permissions="$(stat -c '%A' -- /run)"
[[ "${runtime_permissions:5:1}" != "w" && "${runtime_permissions:8:1}" != "w" ]] \
    || die "The runtime directory is group- or world-writable: /run"
if [[ ! -e "$LOCK_DIRECTORY" && ! -L "$LOCK_DIRECTORY" ]]; then
    install -d -o root -g root -m 0700 "$LOCK_DIRECTORY"
fi
[[ -d "$LOCK_DIRECTORY" && ! -L "$LOCK_DIRECTORY" \
    && "$(stat -c '%u' -- "$LOCK_DIRECTORY")" == "0" \
    && "$(stat -c '%a' -- "$LOCK_DIRECTORY")" == "700" ]] \
    || die "The toolkit lock directory is unsafe: $LOCK_DIRECTORY"
if path_exists "$LOCK_FILE"; then
    [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" \
        && "$(stat -c '%u' -- "$LOCK_FILE")" == "0" ]] \
        || die "The toolkit lock file is unsafe: $LOCK_FILE"
fi
exec 9>>"$LOCK_FILE"
flock -x 9 || die "Could not acquire the OMEN ACPI installation lock."

for state in /var/lib/omen-acpi-s5-test /var/lib/omen-acpi-combined-test; do
    [[ ! -e "$state" && ! -L "$state" ]] \
        || die "Managed state still exists at $state. Remove the corresponding entry with omen-acpi first."
done
for dropin in \
    /etc/limine-entry-tool.d/90-omen-acpi-s5-test.conf \
    /etc/limine-entry-tool.d/91-omen-acpi-combined-test.conf; do
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

# The uninstaller already owns descriptor 9 for the shared toolkit lock. The
# manager validates and reuses that inherited descriptor, locates the mounted
# ESP with its normal fail-closed parser, and proves that neither reserved entry
# name remains before any toolkit path is detached.
OMEN_ACPI_LOCK_FD9_HELD=1 "$MANAGER" pre-uninstall-check

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

bin_moved=1
mv -T -- "$TARGET_BIN" "$removed_bin"
doc_moved=1
mv -T -- "$TARGET_DOC" "$removed_doc"
root_moved=1
mv -T -- "$TARGET_ROOT" "$removed_root"
removal_committed=1
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
