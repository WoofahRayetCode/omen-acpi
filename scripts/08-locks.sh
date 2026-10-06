#!/usr/bin/env bash
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared lock order: Limine boot partition (200), then toolkit state (9).

omen_acpi_acquire_locks() {
    local prefix='' owner=0 path parent descriptor inherited identity actual
    if [[ "${OMEN_ACPI_TESTING:-0}" == 1 && -n "${OMEN_ACPI_TEST_ROOT:-}" ]]; then
        prefix="$OMEN_ACPI_TEST_ROOT"
        owner="$(id -u)"
    fi
    for descriptor in 200 9; do
        if [[ "$descriptor" == 200 ]]; then
            path="$prefix/run/lock/boot-partition.lock"
            inherited="${OMEN_ACPI_BOOT_LOCK_FD200_HELD:-0}"
        else
            path="$prefix/run/omen-acpi-fix/manager.lock"
            inherited="${OMEN_ACPI_LOCK_FD9_HELD:-0}"
        fi
        parent="${path%/*}"
        # Check every parent below /run before following it or creating files.
        local runtime="$prefix/run"
        [[ -d "$runtime" && ! -L "$runtime" && "$(stat -c %u "$runtime")" == "$owner" \
            && "$(stat -c %A "$runtime")" != ?????w???? \
            && "$(stat -c %A "$runtime")" != ????????w? ]] \
            || { printf 'ERROR: unsafe runtime directory: %s\n' "$runtime" >&2; return 1; }
        if [[ ! -e "$parent" && ! -L "$parent" ]]; then
            install -d -m 0700 "$parent" || return 1
        fi
        [[ -d "$parent" && ! -L "$parent" && "$(stat -c %u "$parent")" == "$owner" \
            && "$(stat -c %A "$parent")" != ?????w???? \
            && "$(stat -c %A "$parent")" != ????????w? ]] \
            || { printf 'ERROR: unsafe lock directory: %s\n' "$parent" >&2; return 1; }
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -f "$path" && ! -L "$path" && "$(stat -c %u "$path")" == "$owner" \
                && "$(stat -c %h "$path")" == 1 \
                && "$(stat -c %A "$path")" != ?????w???? \
                && "$(stat -c %A "$path")" != ????????w? ]] \
                || { printf 'ERROR: unsafe lock file: %s\n' "$path" >&2; return 1; }
        fi
        if [[ "$inherited" == 1 ]]; then
            identity="$(stat -c '%d:%i' "$path")" || return 1
            actual="$(stat -Lc '%d:%i' "/proc/self/fd/$descriptor" 2>/dev/null)" || return 1
            [[ "$identity" == "$actual" ]] \
                || { printf 'ERROR: invalid inherited lock descriptor %s\n' "$descriptor" >&2; return 1; }
            if flock -n "$path" true; then
                printf 'ERROR: inherited descriptor %s did not hold its lock\n' "$descriptor" >&2
                return 1
            fi
            # An inherited open-file description must already own the lock.
            flock -n "$descriptor" || return 1
        else
            if [[ "$descriptor" == 200 ]]; then
                exec 200>>"$path" || return 1
            else
                exec 9>>"$path" || return 1
            fi
            if [[ "${OMEN_ACPI_AUTOMATIC:-0}" == 1 ]]; then
                flock -n "$descriptor" || { printf 'WARNING: OMEN ACPI lock contention: %s\n' "$path" >&2; return 75; }
            else
                flock -x "$descriptor" || return 1
            fi
        fi
    done
    export OMEN_ACPI_BOOT_LOCK_FD200_HELD=1 OMEN_ACPI_LOCK_FD9_HELD=1
}
