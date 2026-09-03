#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -u
export PATH="/usr/bin:/bin"

# Pacman PostTransaction helper. Reconcile owned experimental Limine entries
# after a kernel, initramfs, DKMS, NVIDIA-utils or Limine-related update.
# Always exit 0: a conflict or missing installation must not fail the package
# transaction.

readonly MANAGER="${OMEN_ACPI_MANAGER:-/usr/local/lib/omen-acpi-fix/scripts/03-manage-limine-entry.sh}"

if [[ ! -x "$MANAGER" ]]; then
    exit 0
fi

for variant in s5 combined; do
    state="/var/lib/omen-acpi-${variant}-test"
    if [[ "${OMEN_ACPI_TEST_ROOT:-}" ]]; then
        state="${OMEN_ACPI_TEST_ROOT}${state}"
    fi
    [[ -d "$state" && ! -L "$state" ]] || continue
    [[ -f "$state/kernel-entries.json" && ! -L "$state/kernel-entries.json" ]] || continue
    if ! "$MANAGER" refresh "$variant"; then
        printf 'WARNING: omen-acpi refresh %s failed; run omen-acpi refresh %s after this transaction.\n' \
            "$variant" "$variant" >&2
    fi
done

exit 0
