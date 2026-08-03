#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail

# Rebuilds the release artifacts deterministically from the working tree.
#
#   SHA256SUMS                              per-file manifest, inside the archive
#   omen-acpi-toolkit-vX.Y.Z.tar.gz         release archive
#   omen-acpi-toolkit-vX.Y.Z.tar.gz.sha256  external checksum
#
# The archive contains exactly the paths listed in install.sh's release_files
# array plus SHA256SUMS. Repository-only files such as update.sh, docs/ and
# tools/ are deliberately excluded: update.sh's own verifier rejects an archive
# containing anything else.

readonly ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly OUTPUT_DIR="${1:-$ROOT}"

cd "$ROOT"

version="$(sed -n 's/^readonly VERSION="\([0-9.]*\)"$/\1/p' install.sh)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'ERROR: could not read a valid version from install.sh\n' >&2
    exit 1
}

# Every component that declares a version must agree, because update.sh
# refuses to install a release whose declarations diverge.
for file in install.sh omen-acpi scripts/03-manage-limine-entry.sh; do
    grep -Fxq "readonly VERSION=\"$version\"" "$file" || {
        printf 'ERROR: %s does not declare version %s\n' "$file" "$version" >&2
        exit 1
    }
done
grep -Fxq "VERSION = \"$version\"" scripts/04-stock-recovery.py || {
    printf 'ERROR: scripts/04-stock-recovery.py does not declare version %s\n' "$version" >&2
    exit 1
}

mapfile -t release_files < <(
    python3 - <<'PY'
lines = open("install.sh", encoding="utf-8").read().splitlines()
start = lines.index("release_files=(") + 1
end = lines.index(")", start)
for line in lines[start:end]:
    name = line.strip()
    if name:
        print(name)
PY
)
((${#release_files[@]} > 0)) || { printf 'ERROR: empty release_files\n' >&2; exit 1; }

sha256sum -- "${release_files[@]}" > SHA256SUMS
sha256sum -c --strict SHA256SUMS > /dev/null

name="omen-acpi-toolkit-v$version"
staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT

for file in "${release_files[@]}" SHA256SUMS; do
    install -D -m "$(test -x "$file" && echo 0755 || echo 0644)" \
        -- "$file" "$staging/$name/$file"
done

# Fixed owner, sorted order and a fixed mtime keep the archive reproducible.
tar --owner=0 --group=0 --numeric-owner --sort=name \
    --mtime='2026-08-01 00:00:00' \
    -czf "$OUTPUT_DIR/$name.tar.gz" -C "$staging" "$name"

( cd "$OUTPUT_DIR" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )

printf 'Built %s\n' "$OUTPUT_DIR/$name.tar.gz"
cat "$OUTPUT_DIR/$name.tar.gz.sha256"
