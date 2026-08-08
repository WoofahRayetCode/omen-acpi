#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
readonly ORIGINAL_PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}"
export PATH="/usr/bin:/bin"

readonly UPDATER_NAME="OMEN ACPI Toolkit updater"
readonly SELF_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
readonly SELF_DIR="$(dirname -- "$SELF_PATH")"
readonly MAX_ARCHIVE_BYTES=$((128 * 1024 * 1024))
readonly INSTALLED_ROOT="/usr/local/lib/omen-acpi-fix"
readonly INSTALLED_DOC="/usr/local/share/doc/omen-acpi-fix"
readonly INSTALLED_VERSION_FILE="/usr/local/lib/omen-acpi-fix/VERSION"
readonly INSTALLED_CLI="/usr/local/bin/omen-acpi"
readonly INSTALLED_MANAGER="/usr/local/lib/omen-acpi-fix/scripts/03-manage-limine-entry.sh"

archive_argument=''
archive_path=''
checksum_path=''
selected_archive_path=''
temporary_root=''
target_version=''
installed_version='not installed'
assume_yes=0
force_reinstall=0
verify_only=0
color_enabled=0
no_color_requested=0

for initial_argument in "$@"; do
    if [[ "$initial_argument" == "--no-color" ]]; then
        no_color_requested=1
        break
    fi
done

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" \
    && "$no_color_requested" == 0 ]]; then
    color_enabled=1
fi

if (( color_enabled )); then
    readonly RESET=$'\033[0m'
    readonly BOLD=$'\033[1m'
    readonly CYAN=$'\033[36m'
    readonly GREEN=$'\033[32m'
    readonly YELLOW=$'\033[33m'
    readonly RED=$'\033[31m'
else
    readonly RESET=''
    readonly BOLD=''
    readonly CYAN=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly RED=''
fi

die() {
    printf '%bERROR:%b %s\n' "$RED$BOLD" "$RESET" "$*" >&2
    exit 1
}

info() {
    printf '%b==>%b %s\n' "$CYAN$BOLD" "$RESET" "$*"
}

success() {
    printf '%bOK:%b %s\n' "$GREEN$BOLD" "$RESET" "$*"
}

warn() {
    printf '%bWARNING:%b %s\n' "$YELLOW$BOLD" "$RESET" "$*" >&2
}

usage() {
    cat <<'EOF'
OMEN ACPI Toolkit updater

Usage:
  ./update.sh
  ./update.sh /path/to/omen-acpi-toolkit-vX.Y.Z.tar.gz
  ./update.sh --archive /path/to/omen-acpi-toolkit-vX.Y.Z.tar.gz

Options:
  --archive FILE  Use this release archive instead of searching Downloads.
  --verify-only   Verify the archive and both checksum layers without installing.
  --force         Reinstall the same version. Downgrades remain blocked.
  --yes           Skip the final routine confirmation.
  --no-color      Disable coloured output.
  -h, --help      Show this help.

At first launch the updater installs itself as:

  ~/.local/bin/omen-acpi-update

Without --archive, it selects the highest X.Y.Z release found in the current
directory, beside update.sh, or in the user's Scaricati/Downloads directory.
Every archive must have a matching adjacent file named:

  omen-acpi-toolkit-vX.Y.Z.tar.gz.sha256

Run this updater as your normal user, never with sudo. The verified release's
install.sh requests administrator access when needed.
EOF
}

cleanup() {
    case "${temporary_root:-}" in
        /tmp/omen-acpi-update.*)
            if [[ -d "$temporary_root" && ! -L "$temporary_root" ]]; then
                rm -rf -- "$temporary_root"
            fi
            ;;
        '') ;;
        *) warn "Refusing to remove unexpected temporary path: $temporary_root" ;;
    esac
}

on_signal() {
    local signal_name="$1"
    warn "Interrupted by $signal_name."
    case "$signal_name" in
        INT) exit 130 ;;
        HUP) exit 129 ;;
        TERM) exit 143 ;;
        *) exit 1 ;;
    esac
}

trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal HUP' HUP
trap 'on_signal TERM' TERM

valid_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]
}

version_relation() {
    local left="$1"
    local right="$2"
    local -a left_parts right_parts
    local index

    valid_version "$left" || die "Invalid version: $left"
    valid_version "$right" || die "Invalid version: $right"
    IFS=. read -r -a left_parts <<<"$left"
    IFS=. read -r -a right_parts <<<"$right"

    for index in 0 1 2; do
        if (( 10#${left_parts[index]} < 10#${right_parts[index]} )); then
            printf '%s\n' -1
            return 0
        fi
        if (( 10#${left_parts[index]} > 10#${right_parts[index]} )); then
            printf '%s\n' 1
            return 0
        fi
    done
    printf '%s\n' 0
}

downloads_directory() {
    local candidate=''

    if command -v xdg-user-dir >/dev/null 2>&1; then
        candidate="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    fi
    [[ -n "$candidate" && "$candidate" == /* && -d "$candidate" ]] || return 1
    candidate="$(realpath -- "$candidate")"
    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}

version_from_archive_name() {
    local filename="$1"

    if [[ "$filename" =~ ^omen-acpi-toolkit-v((0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8}))\.tar\.gz$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

search_directories=()

add_search_directory() {
    local candidate="${1:-}" resolved existing

    [[ -n "$candidate" && -d "$candidate" ]] || return 0
    resolved="$(realpath -- "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" && "$resolved" == /* && -d "$resolved" ]] || return 0
    for existing in ${search_directories[@]+"${search_directories[@]}"}; do
        [[ "$existing" != "$resolved" ]] || return 0
    done
    search_directories+=("$resolved")
}

collect_search_directories() {
    local directory

    search_directories=()
    add_search_directory "$PWD"
    add_search_directory "$SELF_DIR"
    add_search_directory "$(downloads_directory 2>/dev/null || true)"
    if [[ -n "${HOME:-}" ]]; then
        for directory in "$HOME/Scaricati" "$HOME/Downloads"; do
            add_search_directory "$directory"
        done
    fi
    ((${#search_directories[@]} > 0)) \
        || die "No readable directory could be searched for a release archive."
}

select_download_archive() {
    local directory candidate candidate_name candidate_version best=''
    local best_version='' relation ignored=0
    local -a candidates=()

    collect_search_directories

    for directory in "${search_directories[@]}"; do
        shopt -s nullglob
        candidates=("$directory"/omen-acpi-toolkit-v*.tar.gz)
        shopt -u nullglob

        for candidate in "${candidates[@]}"; do
            [[ -f "$candidate" && ! -L "$candidate" ]] || continue
            candidate_name="$(basename -- "$candidate")"
            candidate_version="$(version_from_archive_name "$candidate_name" 2>/dev/null || true)"
            if [[ -z "$candidate_version" ]]; then
                ((ignored += 1))
                continue
            fi
            if [[ ! -f "$candidate.sha256" || -L "$candidate.sha256" ]]; then
                ((ignored += 1))
                continue
            fi

            if [[ -z "$best" ]]; then
                best="$candidate"
                best_version="$candidate_version"
                continue
            fi
            relation="$(version_relation "$candidate_version" "$best_version")"
            if [[ "$relation" == 1 ]]; then
                best="$candidate"
                best_version="$candidate_version"
            fi
        done
    done

    if (( ignored > 0 )); then
        warn "Ignored $ignored incomplete or noncanonically named release file(s)"
        warn "Keep the exact names omen-acpi-toolkit-vX.Y.Z.tar.gz and .tar.gz.sha256"
    fi
    if [[ -z "$best" ]]; then
        printf '%bERROR:%b %s\n' "$RED$BOLD" "$RESET" \
            "No complete omen-acpi-toolkit-vX.Y.Z release was found. Searched:" >&2
        printf '  %s\n' "${search_directories[@]}" >&2
        exit 1
    fi
    printf '%s\n' "$best"
}

# Best effort identification of the interactive shell that launched this
# updater, so the closing advice is never wrong for the caller's shell.
interactive_shell_name() {
    local candidate=''

    if [[ -r "/proc/$PPID/comm" ]]; then
        read -r candidate < "/proc/$PPID/comm" || candidate=''
    fi
    candidate="${candidate#-}"
    case "$candidate" in
        bash|zsh|fish|ksh|ksh93|mksh|dash|sh)
            printf '%s\n' "$candidate"
            return 0
            ;;
    esac
    candidate="${SHELL:-}"
    candidate="${candidate##*/}"
    printf '%s\n' "$candidate"
}

command_directory_is_in_path() {
    local directory="$1" element

    while IFS= read -r -d ':' element; do
        [[ "$element" != "$directory" ]] || return 0
    done <<<"$ORIGINAL_PATH:"
    return 1
}

report_command_cache_advice() {
    case "$(interactive_shell_name)" in
        fish)
            printf '\nFish resolves commands without a persistent hash table,\n'
            printf 'so omen-acpi is already up to date in this shell.\n'
            ;;
        zsh)
            printf '\nAfter this updater exits, run: rehash\n'
            ;;
        bash|sh|ksh|ksh93|mksh|dash)
            printf '\nAfter this updater exits, run: hash -r\n'
            ;;
        *)
            printf '\nIf your shell caches command locations, refresh it now:\n'
            printf '  bash/ksh: hash -r   zsh: rehash   fish: nothing to do\n'
            ;;
    esac
}

persist_updater() {
    local target_dir target temporary

    (( EUID != 0 )) || return 0
    [[ -n "${HOME:-}" ]] || die "HOME is not set; the updater cannot install itself."
    target_dir="$HOME/.local/bin"
    target="$target_dir/omen-acpi-update"
    mkdir -p -- "$target_dir"
    [[ -d "$target_dir" && ! -L "$target_dir" ]] \
        || die "Updater command directory is unsafe: $target_dir"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] \
            || die "Updater command path is unsafe: $target"
        if cmp -s -- "$SELF_PATH" "$target"; then
            return 0
        fi
    fi

    temporary="$(mktemp "$target_dir/.omen-acpi-update.XXXXXX")"
    if ! cp -- "$SELF_PATH" "$temporary" \
        || ! chmod 0755 "$temporary" \
        || ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        die "Could not install the reusable updater command."
    fi
    success "Reusable updater installed: $target"
    if ! command_directory_is_in_path "$target_dir"; then
        warn "$target_dir is not in PATH; 'omen-acpi-update' will not be found yet."
        if [[ "$(interactive_shell_name)" == fish ]]; then
            warn "In fish, add it once with: fish_add_path \$HOME/.local/bin"
        else
            warn "Add it to PATH in your shell configuration, or call $target directly."
        fi
    fi
}

resolve_archive() {
    local candidate filename

    if [[ -n "$archive_argument" ]]; then
        [[ -f "$archive_argument" && ! -L "$archive_argument" ]] \
            || die "Archive not found or unsafe: $archive_argument"
        candidate="$(realpath -- "$archive_argument")"
    else
        candidate="$(select_download_archive)"
    fi

    filename="$(basename -- "$candidate")"
    target_version="$(version_from_archive_name "$filename" 2>/dev/null || true)"
    [[ -n "$target_version" ]] || die \
        "Expected archive name omen-acpi-toolkit-vX.Y.Z.tar.gz; got: $filename"

    archive_path="$candidate"
    checksum_path="$candidate.sha256"
    [[ -f "$checksum_path" && ! -L "$checksum_path" ]] || die \
        "Matching checksum file not found or unsafe: $checksum_path"

    local archive_size checksum_size
    archive_size="$(stat -c '%s' -- "$archive_path")"
    [[ "$archive_size" =~ ^[0-9]+$ ]] || die "Could not determine archive size."
    (( archive_size > 0 && archive_size <= MAX_ARCHIVE_BYTES )) || die \
        "Archive size is outside the allowed range: $archive_size bytes"
    checksum_size="$(stat -c '%s' -- "$checksum_path")"
    [[ "$checksum_size" =~ ^[0-9]+$ ]] || die "Could not determine checksum size."
    (( checksum_size > 0 && checksum_size <= 512 )) || die \
        "Checksum file size is outside the allowed range: $checksum_size bytes"
}

snapshot_selected_release() {
    local archive_name checksum_name archive_size checksum_size

    [[ -n "$temporary_root" && -d "$temporary_root" && ! -L "$temporary_root" ]] \
        || die "Private update directory is unavailable."
    archive_name="$(basename -- "$archive_path")"
    checksum_name="$archive_name.sha256"
    selected_archive_path="$archive_path"

    cp -- "$archive_path" "$temporary_root/$archive_name"
    cp -- "$checksum_path" "$temporary_root/$checksum_name"
    chmod 0600 "$temporary_root/$archive_name" "$temporary_root/$checksum_name"
    archive_path="$temporary_root/$archive_name"
    checksum_path="$temporary_root/$checksum_name"

    archive_size="$(stat -c '%s' -- "$archive_path")"
    [[ "$archive_size" =~ ^[0-9]+$ ]] || die "Could not determine snapshot size."
    (( archive_size > 0 && archive_size <= MAX_ARCHIVE_BYTES )) || die \
        "Release snapshot size is outside the allowed range: $archive_size bytes"
    checksum_size="$(stat -c '%s' -- "$checksum_path")"
    [[ "$checksum_size" =~ ^[0-9]+$ ]] || die "Could not determine checksum snapshot size."
    (( checksum_size > 0 && checksum_size <= 512 )) || die \
        "Checksum snapshot size is outside the allowed range: $checksum_size bytes"
}

check_commands() {
    local command_name
    local -a missing=()

    for command_name in \
        awk basename cat chmod cmp cp dirname grep mkdir mktemp mv python3 \
        realpath rm sha256sum stat; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if ((${#missing[@]} > 0)); then
        printf 'Missing required commands:' >&2
        printf ' %s' "${missing[@]}" >&2
        printf '\nOn CachyOS/Arch, install their packages with a normal full update, for example:\n' >&2
        printf '  sudo pacman -Syu --needed coreutils gawk grep python\n' >&2
        exit 1
    fi
}

verify_external_checksum() {
    local filename expected_digest actual_digest

    filename="$(basename -- "$archive_path")"
    expected_digest="$(python3 - "$checksum_path" "$filename" <<'PY'
from pathlib import Path
import re
import sys

checksum_path = Path(sys.argv[1])
expected_name = sys.argv[2]
try:
    text = checksum_path.read_text(encoding="ascii")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"cannot read checksum file: {error}") from error

lines = text.splitlines()
if len(lines) != 1:
    raise SystemExit("checksum file must contain exactly one line")
match = re.fullmatch(r"([0-9A-Fa-f]{64})  ([A-Za-z0-9._-]+)", lines[0])
if match is None:
    raise SystemExit("checksum file has an invalid format")
digest, filename = match.groups()
if filename != expected_name:
    raise SystemExit(
        f"checksum names {filename!r}, expected {expected_name!r}"
    )
print(digest.lower())
PY
)" || die "External checksum file validation failed."

    actual_digest="$(sha256sum -- "$archive_path" | awk '{print $1}')"
    [[ "$actual_digest" == "$expected_digest" ]] || die \
        "Archive SHA-256 mismatch; delete it and download the release again."
    success "External SHA-256 verified: $actual_digest"
}

extract_release_safely() {
    local expected_root="omen-acpi-toolkit-v$target_version"
    local extraction_root="$temporary_root/extracted"

    mkdir -m 0700 -- "$extraction_root"
    python3 - "$archive_path" "$extraction_root" "$expected_root" <<'PY'
from pathlib import Path, PurePosixPath
import os
import shutil
import sys
import tarfile

archive_path = Path(sys.argv[1])
destination = Path(sys.argv[2])
expected_root = sys.argv[3]
maximum_members = 1_000
maximum_unpacked_bytes = 256 * 1024 * 1024

try:
    archive = tarfile.open(archive_path, mode="r:gz")
except (OSError, tarfile.TarError) as error:
    raise SystemExit(f"cannot open release archive: {error}") from error

with archive:
    members = archive.getmembers()
    if not members or len(members) > maximum_members:
        raise SystemExit("archive member count is outside the allowed range")

    seen: set[str] = set()
    directories: list[tuple[tarfile.TarInfo, tuple[str, ...]]] = []
    files: list[tuple[tarfile.TarInfo, tuple[str, ...]]] = []
    unpacked_bytes = 0

    for member in members:
        raw_name = member.name
        if (
            not raw_name
            or "\\" in raw_name
            or "\x00" in raw_name
            or any(ord(character) < 32 or ord(character) == 127 for character in raw_name)
        ):
            raise SystemExit(f"unsafe archive member name: {raw_name!r}")
        path = PurePosixPath(raw_name)
        parts = path.parts
        if path.is_absolute() or not parts or any(
            part in {"", ".", ".."} for part in parts
        ):
            raise SystemExit(f"unsafe archive path: {raw_name!r}")
        if parts[0] != expected_root:
            raise SystemExit(f"archive contains an unexpected root: {raw_name!r}")

        normalized = "/".join(parts)
        canonical_name = raw_name[:-1] if member.isdir() and raw_name.endswith("/") else raw_name
        if canonical_name != normalized:
            raise SystemExit(f"noncanonical archive path: {raw_name!r}")
        if normalized in seen:
            raise SystemExit(f"archive contains a duplicate path: {normalized!r}")
        seen.add(normalized)

        if member.isdir():
            directories.append((member, parts))
        elif member.isfile():
            if member.size < 0:
                raise SystemExit(f"archive member has an invalid size: {normalized!r}")
            unpacked_bytes += member.size
            if unpacked_bytes > maximum_unpacked_bytes:
                raise SystemExit("archive expands beyond the allowed size")
            files.append((member, parts))
        else:
            raise SystemExit(
                f"links and special files are forbidden in releases: {normalized!r}"
            )

    directory_names = {"/".join(parts) for _, parts in directories}
    file_names = {"/".join(parts) for _, parts in files}
    if expected_root not in directory_names:
        raise SystemExit("archive root is missing or is not a directory")
    required_files = {
        f"{expected_root}/SHA256SUMS",
        f"{expected_root}/install.sh",
        f"{expected_root}/omen-acpi",
        f"{expected_root}/scripts/03-manage-limine-entry.sh",
    }
    missing = sorted(required_files - file_names)
    if missing:
        raise SystemExit(f"archive is missing required regular files: {missing}")

    for _, parts in sorted(directories, key=lambda item: len(item[1])):
        target = destination.joinpath(*parts)
        target.mkdir(mode=0o755, parents=True, exist_ok=False)

    for member, parts in files:
        target = destination.joinpath(*parts)
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit(f"cannot read archive member: {member.name!r}")
        try:
            with source, target.open("xb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
        except OSError as error:
            raise SystemExit(f"cannot extract {member.name!r}: {error}") from error
        os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)
PY
}

verify_internal_release() {
    local release_root="$temporary_root/extracted/omen-acpi-toolkit-v$target_version"

    python3 - "$release_root" "$target_version" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import re
import sys

root = Path(sys.argv[1])
expected_version = sys.argv[2]

installer = root / "install.sh"
installer_lines = installer.read_text(encoding="utf-8").splitlines()
try:
    start = installer_lines.index("release_files=(") + 1
    end = installer_lines.index(")", start)
except ValueError as error:
    raise SystemExit("could not parse install.sh release manifest") from error

release_files: list[str] = []
for raw in installer_lines[start:end]:
    name = raw.strip()
    if not name or re.fullmatch(r"[A-Za-z0-9._/-]+", name) is None:
        raise SystemExit(f"invalid release file entry: {raw!r}")
    path = PurePosixPath(name)
    if (
        path.is_absolute()
        or path.as_posix() != name
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise SystemExit(f"unsafe release file entry: {name!r}")
    release_files.append(name)
if len(release_files) != len(set(release_files)):
    raise SystemExit("install.sh release file list contains duplicates")

required_release_files = {
    "install.sh",
    "omen-acpi",
    "scripts/03-manage-limine-entry.sh",
    "scripts/04-stock-recovery.py",
    "scripts/05-kernel-entries.py",
}
if not required_release_files.issubset(release_files):
    missing = sorted(required_release_files - set(release_files))
    raise SystemExit(f"release file list omits core executables: {missing}")

manifest_lines = (root / "SHA256SUMS").read_text(encoding="ascii").splitlines()
manifest: dict[str, str] = {}
for line in manifest_lines:
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
    if match is None:
        raise SystemExit("SHA256SUMS contains a malformed line")
    digest, name = match.groups()
    path = PurePosixPath(name)
    if (
        path.is_absolute()
        or path.as_posix() != name
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise SystemExit(f"SHA256SUMS contains an unsafe path: {name!r}")
    if name in manifest:
        raise SystemExit(f"SHA256SUMS repeats {name!r}")
    manifest[name] = digest

if set(manifest) != set(release_files):
    raise SystemExit("SHA256SUMS does not exactly cover install.sh release_files")

actual_files = {
    path.relative_to(root).as_posix()
    for path in root.rglob("*")
    if path.is_file()
}
expected_files = set(release_files) | {"SHA256SUMS"}
if actual_files != expected_files:
    missing = sorted(expected_files - actual_files)
    extra = sorted(actual_files - expected_files)
    raise SystemExit(
        f"extracted release coverage mismatch: missing={missing}, extra={extra}"
    )

for name in release_files:
    path = root / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"release file is missing or unsafe: {name}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != manifest[name]:
        raise SystemExit(f"internal checksum mismatch: {name}")

version_files = [
    root / "install.sh",
    root / "omen-acpi",
    root / "scripts/03-manage-limine-entry.sh",
]
for path in version_files:
    matches = re.findall(
        r'^readonly VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$',
        path.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )
    if matches != [expected_version]:
        raise SystemExit(
            f"version mismatch in {path.relative_to(root)}: {matches!r}"
        )

manager = root / "scripts/04-stock-recovery.py"
matches = re.findall(r'^VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"$', manager.read_text(encoding="utf-8"), flags=re.MULTILINE)
if matches != [expected_version]:
    raise SystemExit(f"version mismatch in {manager.relative_to(root)}: {matches!r}")

print(f"verified {len(release_files)} internal release files")
PY

    (
        cd "$release_root"
        sha256sum -c SHA256SUMS
    )
    success "Internal release manifest and version $target_version verified."
}

read_installed_version() {
    local -a lines=()

    if [[ ! -e "$INSTALLED_VERSION_FILE" && ! -L "$INSTALLED_VERSION_FILE" ]]; then
        installed_version='not installed'
        return 0
    fi
    [[ -f "$INSTALLED_VERSION_FILE" && ! -L "$INSTALLED_VERSION_FILE" ]] \
        || die "Installed VERSION path is unsafe: $INSTALLED_VERSION_FILE"
    mapfile -t lines < "$INSTALLED_VERSION_FILE"
    [[ ${#lines[@]} -eq 1 ]] || die "Installed VERSION file is malformed."
    valid_version "${lines[0]}" || die "Installed VERSION is invalid: ${lines[0]}"
    installed_version="${lines[0]}"
}

installation_is_partial() {
    local target present=0 total=0

    for target in "$INSTALLED_ROOT" "$INSTALLED_CLI" "$INSTALLED_DOC"; do
        ((total += 1))
        if [[ -e "$target" || -L "$target" ]]; then
            ((present += 1))
        fi
    done
    (( present > 0 && present < total ))
}

installed_layout_matches_target() {
    local cli_version manager_version

    [[ "$installed_version" == "$target_version" ]] || return 1
    ! installation_is_partial || return 1
    [[ -d "$INSTALLED_ROOT" && ! -L "$INSTALLED_ROOT" ]] || return 1
    [[ -d "$INSTALLED_DOC" && ! -L "$INSTALLED_DOC" ]] || return 1
    [[ -x "$INSTALLED_CLI" && ! -L "$INSTALLED_CLI" ]] || return 1
    [[ -f "$INSTALLED_MANAGER" && ! -L "$INSTALLED_MANAGER" ]] || return 1
    cli_version="$($INSTALLED_CLI --plain version 2>/dev/null || true)"
    [[ "$cli_version" == "OMEN ACPI Toolkit $target_version" ]] || return 1
    manager_version="$(grep -m1 '^readonly VERSION=' "$INSTALLED_MANAGER" 2>/dev/null || true)"
    [[ "$manager_version" == "readonly VERSION=\"$target_version\"" ]]
}

confirm_installation() {
    local answer

    (( assume_yes )) && return 0
    [[ -t 0 ]] || die "Interactive confirmation is unavailable; rerun with --yes."
    printf '\nInstall OMEN ACPI Toolkit %s now? [y/N] ' "$target_version"
    read -r answer
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) info "Update cancelled."; return 1 ;;
    esac
}

install_release() {
    local release_root="$temporary_root/extracted/omen-acpi-toolkit-v$target_version"
    local cli_version manager_version
    local -a installer_arguments=()

    [[ -x "$release_root/install.sh" && ! -L "$release_root/install.sh" ]] \
        || die "Verified installer is not executable."
    [[ -x /usr/bin/sudo && ! -L /usr/bin/sudo ]] \
        || die "/usr/bin/sudo is required for installation."

    if installation_is_partial; then
        warn "The installation under /usr/local is partial; requesting a repairing install."
        installer_arguments+=(--repair)
    fi

    info "Starting the verified transactional installer."
    /usr/bin/sudo -- "$release_root/install.sh" \
        ${installer_arguments[@]+"${installer_arguments[@]}"}

    read_installed_version
    [[ "$installed_version" == "$target_version" ]] || die \
        "Post-install version mismatch: expected $target_version, got $installed_version"
    [[ -x "$INSTALLED_CLI" && ! -L "$INSTALLED_CLI" ]] \
        || die "Installed CLI is missing or unsafe: $INSTALLED_CLI"
    [[ -f "$INSTALLED_MANAGER" && ! -L "$INSTALLED_MANAGER" ]] \
        || die "Installed manager is missing or unsafe: $INSTALLED_MANAGER"

    cli_version="$($INSTALLED_CLI --plain version)"
    [[ "$cli_version" == "OMEN ACPI Toolkit $target_version" ]] || die \
        "Installed CLI reported an unexpected version: $cli_version"
    manager_version="$(grep -m1 '^readonly VERSION=' "$INSTALLED_MANAGER" || true)"
    [[ "$manager_version" == "readonly VERSION=\"$target_version\"" ]] || die \
        "Installed manager reported an unexpected version: $manager_version"

    printf '\n%bUpdate complete.%b\n' "$GREEN$BOLD" "$RESET"
    printf 'CLI:     %s\n' "$cli_version"
    printf 'Manager: %s\n' "$manager_version"
    printf '\nCommands named omen-acpi found in PATH:\n'
    PATH="$ORIGINAL_PATH" type -a omen-acpi || true
    if [[ -d /var/lib/omen-acpi-s5-test || -d /var/lib/omen-acpi-combined-test ]]; then
        printf '\nReconciling existing managed entries with installed standard/LTS kernels.\n'
        if ! "$INSTALLED_CLI" --plain --yes refresh all; then
            warn "Program update succeeded, but entry migration needs attention; run 'omen-acpi refresh all'."
        fi
    fi
    report_command_cache_advice
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --archive)
                (($# >= 2)) || die "--archive requires a file path."
                [[ -z "$archive_argument" ]] || die "Only one archive may be selected."
                archive_argument="$2"
                shift 2
                ;;
            --verify-only)
                verify_only=1
                shift
                ;;
            --force)
                force_reinstall=1
                shift
                ;;
            --yes)
                assume_yes=1
                shift
                ;;
            --no-color)
                color_enabled=0
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --*)
                die "Unknown option: $1"
                ;;
            *)
                [[ -z "$archive_argument" ]] || die "Only one archive may be selected."
                archive_argument="$1"
                shift
                ;;
        esac
    done
}

main() {
    local relation

    parse_arguments "$@"
    if (( EUID == 0 && verify_only == 0 )); then
        die "Run update.sh as your normal user, without sudo."
    fi
    check_commands
    resolve_archive
    temporary_root="$(mktemp -d /tmp/omen-acpi-update.XXXXXX)"
    chmod 0700 "$temporary_root"
    snapshot_selected_release

    printf '%b%s%b\n' "$BOLD" "$UPDATER_NAME" "$RESET"
    printf 'Archive: %s\n' "$selected_archive_path"
    printf 'Target:  %s\n\n' "$target_version"

    verify_external_checksum
    extract_release_safely
    verify_internal_release
    if (( verify_only == 0 )); then
        persist_updater
    fi
    read_installed_version

    printf '\nInstalled version: %s\n' "$installed_version"
    printf 'Release version:   %s\n' "$target_version"

    if (( verify_only )); then
        success "Verification completed; installation was not started."
        exit 0
    fi

    if [[ "$installed_version" != 'not installed' ]]; then
        relation="$(version_relation "$target_version" "$installed_version")"
        if [[ "$relation" == -1 ]]; then
            die "Downgrade from $installed_version to $target_version is blocked."
        fi
        if [[ "$relation" == 0 && "$force_reinstall" != 1 ]]; then
            if installed_layout_matches_target; then
                success "Version $target_version is already installed and consistent; nothing changed."
                printf 'Use --force only if you intentionally need to reinstall it.\n'
                exit 0
            fi
            warn "The VERSION file reports $target_version, but the installed layout is incomplete or inconsistent."
            warn "The verified release will repair the program installation."
        fi
    fi

    printf '\nThe toolkit program will be updated first.\n'
    printf 'Existing managed entries are then reconciled transactionally with standard/LTS kernels.\n'
    confirm_installation || exit 0
    install_release
}

main "$@"
