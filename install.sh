#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

readonly VERSION="2.1.11"
readonly TARGET_ROOT="/usr/local/lib/omen-acpi-fix"
readonly TARGET_BIN="/usr/local/bin/omen-acpi"
readonly TARGET_DOC="/usr/local/share/doc/omen-acpi-fix"
readonly LOCK_DIRECTORY="/run/omen-acpi-fix"
readonly LOCK_FILE="$LOCK_DIRECTORY/manager.lock"
readonly SELF_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

source_snapshot=''
app_stage=''
bin_stage=''
doc_stage=''
root_backup=''
bin_backup=''
doc_backup=''
root_backed_up=0
bin_backed_up=0
doc_backed_up=0
root_activated=0
bin_activated=0
doc_activated=0
transaction_started=0
transaction_committed=0
repair_mode=0

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

safe_remove_directory() {
    local path="${1:-}"
    case "$path" in
        /var/tmp/omen-acpi-install-source.*|\
        /usr/local/lib/.omen-acpi-fix.new.*|\
        /usr/local/lib/.omen-acpi-fix.previous.*|\
        /usr/local/share/doc/.omen-acpi-fix.new.*|\
        /usr/local/share/doc/.omen-acpi-fix.previous.*)
            if path_exists "$path"; then
                rm -rf -- "$path" || warn "Could not remove temporary directory: $path"
            fi
            ;;
        '')
            ;;
        *)
            warn "Refusing to remove unexpected directory path: $path"
            ;;
    esac
}

safe_remove_file() {
    local path="${1:-}"
    case "$path" in
        /usr/local/bin/.omen-acpi.new.*|/usr/local/bin/.omen-acpi.previous.*)
            if path_exists "$path"; then
                rm -f -- "$path" || warn "Could not remove temporary file: $path"
            fi
            ;;
        '')
            ;;
        *)
            warn "Refusing to remove unexpected file path: $path"
            ;;
    esac
}

rollback_transaction() {
    (( transaction_started )) || return 0
    warn "Installation failed; restoring the previous /usr/local installation."

    if (( bin_activated )) && path_exists "$TARGET_BIN"; then
        rm -f -- "$TARGET_BIN" \
            || warn "Could not remove the newly activated command: $TARGET_BIN"
    fi
    if (( doc_activated )) && path_exists "$TARGET_DOC"; then
        rm -rf -- "$TARGET_DOC" \
            || warn "Could not remove the newly activated documentation: $TARGET_DOC"
    fi
    if (( root_activated )) && path_exists "$TARGET_ROOT"; then
        rm -rf -- "$TARGET_ROOT" \
            || warn "Could not remove the newly activated program directory: $TARGET_ROOT"
    fi

    if (( root_backed_up )); then
        if ! path_exists "$TARGET_ROOT"; then
            mv -T -- "$root_backup" "$TARGET_ROOT" \
                || warn "Could not restore the previous program directory from: $root_backup"
        else
            warn "Previous program directory remains preserved at: $root_backup"
        fi
    fi
    if (( doc_backed_up )); then
        if ! path_exists "$TARGET_DOC"; then
            mv -T -- "$doc_backup" "$TARGET_DOC" \
                || warn "Could not restore the previous documentation from: $doc_backup"
        else
            warn "Previous documentation remains preserved at: $doc_backup"
        fi
    fi
    if (( bin_backed_up )); then
        if ! path_exists "$TARGET_BIN"; then
            mv -T -- "$bin_backup" "$TARGET_BIN" \
                || warn "Could not restore the previous public command from: $bin_backup"
        else
            warn "Previous public command remains preserved at: $bin_backup"
        fi
    fi
    transaction_started=0
}

cleanup_stages() {
    safe_remove_directory "$app_stage"
    safe_remove_directory "$doc_stage"
    safe_remove_file "$bin_stage"
    safe_remove_directory "$source_snapshot"
}

cleanup_backups() {
    safe_remove_directory "$root_backup"
    safe_remove_directory "$doc_backup"
    safe_remove_file "$bin_backup"
}

on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    if (( rc != 0 && ! transaction_committed )); then
        rollback_transaction
    fi
    cleanup_stages
    if (( transaction_committed )); then
        cleanup_backups
    fi
    exit "$rc"
}

original_arguments=("$@")

while (($# > 0)); do
    case "$1" in
        -h|--help)
            cat <<'EOF'
Usage: ./install.sh [--repair]

Install the OMEN ACPI Toolkit under /usr/local. The installer verifies an exact
release manifest from a private root snapshot and installs one public command:
omen-acpi.

Options:
  --repair  Also accept a partial installation, meaning that only some of the
            program directory, the public command and the documentation are
            present, and rebuild all three from this verified release.
EOF
            exit 0
            ;;
        --repair)
            repair_mode=1
            shift
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

for command in bash cat chmod chown cmp dirname flock install mktemp mv realpath rm sha256sum stat; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

if (( EUID != 0 )); then
    [[ -x /usr/bin/sudo ]] || die "sudo is required to install under /usr/local."
    exec /usr/bin/sudo -- "$(realpath -- "$0")" \
        ${original_arguments[@]+"${original_arguments[@]}"}
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

trap on_exit EXIT

release_files=(
    .github/workflows/tests.yml
    .gitignore
    CHANGELOG.md
    LICENSE
    README.md
    SECURITY.md
    install.sh
    omen-acpi
    patches/README.md
    scripts/00-probe-boot.sh
    scripts/01-collect-acpi.sh
    scripts/02-build-dsdt.sh
    scripts/03-manage-limine-entry.sh
    scripts/04-stock-recovery.py
    tests/run.sh
    tests/test_interactive_menus.sh
    tests/test_stock_recovery.py
    tests/test_transform.py
    uninstall.sh
)

[[ -f "$SELF_DIR/SHA256SUMS" && ! -L "$SELF_DIR/SHA256SUMS" ]] \
    || die "SHA256SUMS is missing or is a symlink."
for relative in "${release_files[@]}"; do
    [[ -f "$SELF_DIR/$relative" && ! -L "$SELF_DIR/$relative" ]] \
        || die "Required release file is missing or is a symlink: $relative"
done

# Snapshot every verified input before parsing the manifest. All later reads use
# this root-only copy, so a concurrent change in the download directory cannot
# alter the bytes that are ultimately installed.
source_snapshot="$(mktemp -d /var/tmp/omen-acpi-install-source.XXXXXX)"
chmod 0700 "$source_snapshot"
install -o root -g root -m 0600 "$SELF_DIR/SHA256SUMS" "$source_snapshot/SHA256SUMS"
for relative in "${release_files[@]}"; do
    install -d -o root -g root -m 0700 "$source_snapshot/$(dirname -- "$relative")"
    install -o root -g root -m 0600 \
        "$SELF_DIR/$relative" \
        "$source_snapshot/$relative"
done

declare -A seen_manifest=()
while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    manifest_hash="${manifest_line%% *}"
    manifest_remainder="${manifest_line#"$manifest_hash"}"
    [[ "${#manifest_hash}" == 64 && "$manifest_hash" != *[!0-9A-Fa-f]* \
        && "$manifest_remainder" == '  '* ]] \
        || die "SHA256SUMS contains a malformed line."
    manifest_path="${manifest_remainder:2}"
    manifest_expected=0
    for relative in "${release_files[@]}"; do
        if [[ "$manifest_path" == "$relative" ]]; then
            manifest_expected=1
            break
        fi
    done
    (( manifest_expected )) \
        || die "SHA256SUMS contains an unexpected path: $manifest_path"
    [[ -z "${seen_manifest[$manifest_path]+present}" ]] \
        || die "SHA256SUMS contains a duplicate path: $manifest_path"
    seen_manifest["$manifest_path"]=1
done < "$source_snapshot/SHA256SUMS"

for relative in "${release_files[@]}"; do
    [[ -n "${seen_manifest[$relative]+present}" ]] \
        || die "SHA256SUMS does not cover required file: $relative"
done

(
    cd "$source_snapshot"
    sha256sum --check --strict SHA256SUMS
) || die "Release checksum verification failed."

ensure_root_directory() {
    local path="$1" mode="${2:-0755}" owner permissions
    if path_exists "$path"; then
        [[ -d "$path" && ! -L "$path" ]] \
            || die "Required installation parent is not a normal directory: $path"
        owner="$(stat -c '%u' -- "$path")"
        permissions="$(stat -c '%A' -- "$path")"
        [[ "$owner" == "0" ]] \
            || die "Required installation parent is not owned by root: $path"
        [[ "${permissions:5:1}" != "w" && "${permissions:8:1}" != "w" ]] \
            || die "Required installation parent is group- or world-writable: $path"
    else
        install -d -o root -g root -m "$mode" "$path"
    fi
}

ensure_root_directory /usr/local
ensure_root_directory /usr/local/bin
ensure_root_directory /usr/local/lib
ensure_root_directory /usr/local/share
ensure_root_directory /usr/local/share/doc

existing_targets=0
for target in "$TARGET_ROOT" "$TARGET_BIN" "$TARGET_DOC"; do
    if path_exists "$target"; then
        ((existing_targets += 1))
    fi
done

if (( existing_targets != 0 && existing_targets != 3 && repair_mode == 0 )); then
    die "A partial or conflicting installation already exists under /usr/local; rerun this installer with --repair to rebuild it from this verified release."
fi

# Every target that is present must be a root-owned regular path before the
# transaction starts, whether the installation is complete or being repaired.
if path_exists "$TARGET_ROOT"; then
    [[ -d "$TARGET_ROOT" && ! -L "$TARGET_ROOT" ]] \
        || die "Existing install path is not a normal directory: $TARGET_ROOT"
    [[ "$(stat -c '%u' -- "$TARGET_ROOT")" == "0" ]] \
        || die "Existing install path is not owned by root: $TARGET_ROOT"
fi
if path_exists "$TARGET_BIN"; then
    [[ -f "$TARGET_BIN" && ! -L "$TARGET_BIN" ]] \
        || die "Existing public command is not a normal file: $TARGET_BIN"
    [[ "$(stat -c '%u' -- "$TARGET_BIN")" == "0" ]] \
        || die "Existing public command is not owned by root: $TARGET_BIN"
fi
if path_exists "$TARGET_DOC"; then
    [[ -d "$TARGET_DOC" && ! -L "$TARGET_DOC" ]] \
        || die "Existing documentation path is not a normal directory: $TARGET_DOC"
    [[ "$(stat -c '%u' -- "$TARGET_DOC")" == "0" ]] \
        || die "Existing documentation path is not owned by root: $TARGET_DOC"
fi

if (( existing_targets == 3 )); then
    [[ -f "$TARGET_ROOT/omen-acpi" && ! -L "$TARGET_ROOT/omen-acpi" ]] \
        || die "Existing installation does not contain its reference executable."
    cmp -s -- "$TARGET_BIN" "$TARGET_ROOT/omen-acpi" \
        || die "Existing public command differs from the installed reference executable."
elif (( existing_targets != 0 )); then
    warn "Repairing a partial installation; all three toolkit paths will be rebuilt from this release."
fi

app_stage="$(mktemp -d /usr/local/lib/.omen-acpi-fix.new.XXXXXX)"
doc_stage="$(mktemp -d /usr/local/share/doc/.omen-acpi-fix.new.XXXXXX)"
bin_stage="$(mktemp /usr/local/bin/.omen-acpi.new.XXXXXX)"

install -d -o root -g root -m 0755 "$app_stage/scripts"
install -o root -g root -m 0755 "$source_snapshot/omen-acpi" "$app_stage/omen-acpi"
install -o root -g root -m 0755 "$source_snapshot/uninstall.sh" "$app_stage/uninstall.sh"
for script_name in \
    00-probe-boot.sh \
    01-collect-acpi.sh \
    02-build-dsdt.sh \
    03-manage-limine-entry.sh; do
    install -o root -g root -m 0755 \
        "$source_snapshot/scripts/$script_name" \
        "$app_stage/scripts/$script_name"
done
install -o root -g root -m 0755 \
    "$source_snapshot/scripts/04-stock-recovery.py" \
    "$app_stage/scripts/04-stock-recovery.py"
printf '%s\n' "$VERSION" > "$app_stage/VERSION"
chown root:root "$app_stage/VERSION"
chmod 0644 "$app_stage/VERSION"
chmod 0755 "$app_stage"

install -o root -g root -m 0755 "$app_stage/omen-acpi" "$bin_stage"

install -d -o root -g root -m 0755 "$doc_stage/patches"
install -o root -g root -m 0644 \
    "$source_snapshot/README.md" \
    "$source_snapshot/CHANGELOG.md" \
    "$source_snapshot/SECURITY.md" \
    "$source_snapshot/LICENSE" \
    "$doc_stage/"
install -o root -g root -m 0644 \
    "$source_snapshot/patches/README.md" \
    "$doc_stage/patches/README.md"
chmod 0755 "$doc_stage"

transaction_token="${source_snapshot##*.}"
root_backup="/usr/local/lib/.omen-acpi-fix.previous.$transaction_token"
bin_backup="/usr/local/bin/.omen-acpi.previous.$transaction_token"
doc_backup="/usr/local/share/doc/.omen-acpi-fix.previous.$transaction_token"
for backup in "$root_backup" "$bin_backup" "$doc_backup"; do
    ! path_exists "$backup" || die "Unexpected transaction backup path already exists: $backup"
done

transaction_started=1
if path_exists "$TARGET_ROOT"; then
    mv -T -- "$TARGET_ROOT" "$root_backup"
    root_backed_up=1
fi
if path_exists "$TARGET_DOC"; then
    mv -T -- "$TARGET_DOC" "$doc_backup"
    doc_backed_up=1
fi
if path_exists "$TARGET_BIN"; then
    mv -T -- "$TARGET_BIN" "$bin_backup"
    bin_backed_up=1
fi

root_activated=1
mv -T -- "$app_stage" "$TARGET_ROOT"
app_stage=''
doc_activated=1
mv -T -- "$doc_stage" "$TARGET_DOC"
doc_stage=''
bin_activated=1
mv -T -- "$bin_stage" "$TARGET_BIN"
bin_stage=''
transaction_committed=1

cleanup_backups
root_backup=''
doc_backup=''
bin_backup=''
cleanup_stages
source_snapshot=''
trap - EXIT

if (( existing_targets == 3 )); then
    printf '\nOMEN ACPI Toolkit updated successfully to %s.\n' "$VERSION"
elif (( existing_targets != 0 )); then
    printf '\nOMEN ACPI Toolkit %s repaired successfully over a partial installation.\n' "$VERSION"
else
    printf '\nOMEN ACPI Toolkit %s installed successfully.\n' "$VERSION"
fi
printf 'Run it as your normal user:\n\n'
printf '  omen-acpi\n\n'
printf 'The guided CLI will check the machine, boot state and dependencies.\n'
printf 'Program updates never rewrite Limine entries automatically.\n'
printf 'After a kernel/initramfs update, remove and freshly install each experimental entry from the CLI.\n'
