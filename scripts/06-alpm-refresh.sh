#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -u
umask 077
export PATH="/usr/bin:/bin"

# Pacman PostTransaction helper. Reconcile owned experimental Limine entries
# after a kernel, initramfs, DKMS, NVIDIA-utils or Limine-related update.
# Always exit 0: a conflict or missing installation must not fail the package
# transaction.

readonly MANAGER="${OMEN_ACPI_MANAGER:-/usr/local/lib/omen-acpi-fix/scripts/03-manage-limine-entry.sh}"
readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly MAINTENANCE="$SCRIPT_DIR/07-maintenance.py"

[[ "${OMEN_ACPI_INTERNAL_OPERATION:-0}" == 1 ]] && exit 0
export OMEN_ACPI_AUTOMATIC=1
installed=()
for variant in s5 combined s5-vfio; do
    prefix=''
    [[ "${OMEN_ACPI_TESTING:-0}" != 1 ]] || prefix="${OMEN_ACPI_TEST_ROOT:-}"
    state="$prefix/var/lib/omen-acpi-${variant}-test"
    [[ -d "$state" && ! -L "$state" && -f "$state/kernel-entries.json" && ! -L "$state/kernel-entries.json" ]] \
        && installed+=("$variant")
done
((${#installed[@]})) || exit 0

warning() {
    printf 'WARNING: %s\n' "$*" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t omen-acpi -p user.warning -- "$*" 2>/dev/null || true
    fi
}

lock_rc=0
# shellcheck source=scripts/08-locks.sh
if [[ -r "$SCRIPT_DIR/08-locks.sh" ]]; then
    source "$SCRIPT_DIR/08-locks.sh"
    omen_acpi_acquire_locks || lock_rc=$?
else
    lock_rc=1
fi

for variant in "${installed[@]}"; do
    state="/var/lib/omen-acpi-${variant}-test"
    if [[ "${OMEN_ACPI_TESTING:-0}" == 1 && -n "${OMEN_ACPI_TEST_ROOT:-}" ]]; then
        state="${OMEN_ACPI_TEST_ROOT}${state}"
    fi
    [[ -d "$state" && ! -L "$state" ]] || continue
    [[ -f "$state/kernel-entries.json" && ! -L "$state/kernel-entries.json" ]] || continue
    rc="$lock_rc"
    if (( rc == 0 )); then
        if [[ -x "$MANAGER" && ! -L "$MANAGER" ]]; then
            "$MANAGER" refresh "$variant" || rc=$?
        else
            rc=127
        fi
    fi
    if (( rc != 0 )); then
        warning "omen-acpi refresh $variant failed (exit $rc); run omen-acpi refresh $variant."
    fi
    python3 "$MAINTENANCE" record --variant "$variant" --code "$rc" \
        --caller "${HOOK_CALLER:-alpm}" \
        || warning "Could not record automatic refresh for $variant; run omen-acpi doctor."
done

exit 0
