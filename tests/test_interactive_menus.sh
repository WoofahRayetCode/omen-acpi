#!/usr/bin/env bash
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d /tmp/omen-acpi-interactive-test.XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" OMEN_ACPI_TESTING=1 OMEN_ACPI_SOURCE_ONLY=1
mkdir -p "$HOME"
# shellcheck source=../omen-acpi
source "$ROOT/omen-acpi"

fail() { printf 'interactive regression failure: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" <<<"$1" || fail "$3"; }

dependency_specifications stock-recovery | grep -Fxq 'mkinitcpio|lsinitcpio' \
    || fail "stock-recovery dependency profile omits lsinitcpio"

choose() {
    local input="$1" rc=0
    SETUP_VARIANT_RESULT='sentinel'
    choose_setup_variant <<<"$input" > "$work/choose.out" || rc=$?
    printf '%s\n%s\n' "$rc" "$SETUP_VARIANT_RESULT"
    cat "$work/choose.out"
}

for mapping in ':s5' '1:s5' '2:combined' '3:both'; do
    input="${mapping%%:*}" expected="${mapping#*:}"
    result="$(choose "$input")"
    [[ "$(sed -n '1p' <<<"$result")" == 0 ]] || fail "valid setup selection failed"
    [[ "$(sed -n '2p' <<<"$result")" == "$expected" ]] || fail "setup result was contaminated"
    output="$(sed -n '3,$p' <<<"$result")"
    contains "$output" 'Choose the experimental setup:' "guided menu heading is hidden"
    contains "$output" '1. S5-only' "S5 menu line is hidden"
    contains "$output" 'Recommended — confirmed shutdown correction' "recommendation is hidden"
    contains "$output" '2. Combined' "Combined menu line is hidden"
    contains "$output" '3. Both' "Both menu line is hidden"
    contains "$output" 'b. Back' "Back menu line is hidden"
done

PLAIN_MODE=1
plain_setup="$(choose 1)"
printf '%s' "$plain_setup" | LC_ALL=C grep -q '[^ -~[:space:]]' \
    && fail "plain setup menu emitted a non-ASCII character"
contains "$plain_setup" 'Recommended - confirmed shutdown correction' \
    "plain setup menu lost its ASCII recommendation"
PLAIN_MODE=0

result="$(choose b)"; [[ "$(sed -n '1p' <<<"$result")" == 1 && -z "$(sed -n '2p' <<<"$result")" ]] \
    || fail "Back did not cancel cleanly"
SETUP_VARIANT_RESULT=sentinel; choose_setup_variant </dev/null > "$work/eof.out" || true; eof_output="$(<"$work/eof.out")"
[[ -z "$SETUP_VARIANT_RESULT" ]] || fail "EOF retained a setup result"
contains "$eof_output" 'Choose the experimental setup:' "EOF hid the menu"
SETUP_VARIANT_RESULT=sentinel; choose_setup_variant <<<'x
2' > "$work/invalid-setup.out"; invalid_output="$(<"$work/invalid-setup.out")"
[[ "$SETUP_VARIANT_RESULT" == combined ]] || fail "invalid input did not reprompt"
[[ "$(grep -c 'Choose the experimental setup:' <<<"$invalid_output")" -eq 2 ]] || fail "invalid input did not redraw menu"

if grep -Fn 'requested="$(choose_setup_variant)"' "$ROOT/omen-acpi" >/dev/null; then
    fail "interactive setup function is executed by command substitution"
fi
grep -Fq 'requested="$SETUP_VARIANT_RESULT"' "$ROOT/omen-acpi" || fail "explicit setup result variable is missing"
if grep -En 'eval .*SETUP|SETUP.*eval' "$ROOT/omen-acpi" >/dev/null; then fail "setup selection uses eval"; fi

confirmation="$work/confirmation"
confirm() { printf '%s\n' "$1" > "$confirmation"; return 1; }
require_transform_machine() { :; }
require_stock_boot() { printf 'modified\n' >> "$work/actions"; }
guided_output="$(guided_setup <<<2)"
contains "$guided_output" 'Selected setup: Combined' "readable setup selection was not shown"
contains "$(<"$confirmation")" 'Continue with the Combined experimental setup?' "specific confirmation did not follow selection"
[[ ! -e "$work/actions" ]] || fail "negative confirmation allowed a modification"

prepare_stock_recovery() { printf 'recovery-write\n' >> "$work/install-order-actions"; }
ensure_admin() { :; }
run_logged() { return 1; }
for schema in managed conflict; do
    : > "$work/install-order-actions"
    TEST_SCHEMA="$schema"
    inspect_variant_schema() { printf '%s\n' "$TEST_SCHEMA"; }
    if ( install_one s5 ) >"$work/install-$schema.out" 2>"$work/install-$schema.err"; then
        fail "$schema variant schema was unexpectedly accepted"
    fi
    [[ ! -s "$work/install-order-actions" ]] \
        || fail "$schema variant refreshed stock recovery before schema rejection"
done

pause_for_user() { :; }
ensure_dependencies() { :; }
probe_boot() { PROBE_STATE=s5; PROBE_CLEAN=0; PROBE_REVISION=0x0107200A; PROBE_REASON=test; }
probe_boot_if_cached() { probe_boot; }
boot_state_label() { printf 'S5-only'; }
stock_recovery_status() {
    printf 'SNAPSHOT\tvalid\nNORMAL_ENTRY\tavailable\nRECOVERY_ENTRY\tmissing\n'
}
probe_boot() { PROBE_STATE=unknown; PROBE_CLEAN=0; PROBE_REVISION=unknown; PROBE_REASON=ambiguous; }
if ( recover_stock ) >"$work/ambiguous.out" 2>"$work/ambiguous.err"; then
    fail "ambiguous boot state was accepted for recovery"
fi
contains "$(<"$work/ambiguous.err")" 'automatic recovery is blocked' "ambiguous recovery did not fail closed"
probe_boot() { PROBE_STATE=s5; PROBE_CLEAN=0; PROBE_REVISION=0x0107200A; PROBE_REASON=test; }

ensure_admin() { :; }
show_stock_reboot_prompt() { printf 'stock-reboot-prompt\n' >> "$work/legacy-actions"; }
LEGACY_NORMAL_STATE=available
RECOVER_RESULT='NORMAL	Linux-CachyOS'
stock_recovery_manager() {
    case "$1" in
        status)
            printf 'SNAPSHOT\trefresh-required\nNORMAL_ENTRY\t%s\nRECOVERY_ENTRY\tlegacy-untrusted\n' \
                "$LEGACY_NORMAL_STATE"
            ;;
        recover)
            printf 'manager-recover\n' >> "$work/legacy-actions"
            [[ -n "$RECOVER_RESULT" ]] || return 1
            printf '%b\n' "$RECOVER_RESULT"
            ;;
        *) return 1 ;;
    esac
}
: > "$work/legacy-actions"
legacy_output="$(recover_stock 2>&1)"
contains "$legacy_output" '2.1.10 recovery snapshot is untrusted for boot and will be preserved' \
    "legacy recovery did not explain that the snapshot is preserved"
contains "$legacy_output" 'choose recovery option 1' \
    "legacy recovery omitted the post-boot 2.5.0 refresh instruction"
[[ "$(<"$work/legacy-actions")" == $'manager-recover\nstock-reboot-prompt' ]] \
    || fail "legacy recovery did not reach the verified normal-entry reboot prompt"

for LEGACY_NORMAL_STATE in missing ambiguous unusable; do
    : > "$work/legacy-actions"
    if ( recover_stock ) >"$work/legacy-$LEGACY_NORMAL_STATE.out" 2>"$work/legacy-$LEGACY_NORMAL_STATE.err"; then
        fail "legacy recovery accepted a $LEGACY_NORMAL_STATE normal entry"
    fi
    contains "$(<"$work/legacy-$LEGACY_NORMAL_STATE.err")" 'external recovery media' \
        "legacy $LEGACY_NORMAL_STATE state did not require external media"
    [[ ! -s "$work/legacy-actions" ]] \
        || fail "legacy $LEGACY_NORMAL_STATE state invoked the recovery manager"
done

LEGACY_NORMAL_STATE=available
RECOVER_RESULT=''
: > "$work/legacy-actions"
if ( recover_stock ) >"$work/legacy-race.out" 2>"$work/legacy-race.err"; then
    fail "legacy preview race was accepted after the normal entry disappeared"
fi
contains "$(<"$work/legacy-race.err")" 'Automatic stock recovery is unavailable' \
    "legacy preview race did not fail through the authoritative manager"
[[ "$(<"$work/legacy-actions")" == 'manager-recover' ]] \
    || fail "legacy preview race reached a reboot prompt or modified an entry"

prepare_stock_recovery_interactive() { printf 'prepare\n' >> "$work/menu-actions"; }
recover_stock() { printf 'recover\n' >> "$work/menu-actions"; }
show_stock_recovery_details() { printf 'status\n' >> "$work/menu-actions"; }
remove_stock_recovery() { printf 'remove\n' >> "$work/menu-actions"; }

for mapping in '1:prepare' '2:recover' '3:status' '4:remove'; do
    : > "$work/menu-actions"
    key="${mapping%%:*}" expected="${mapping#*:}"
    menu_output="$(stock_recovery_menu <<<"$key
b")"
    [[ "$(<"$work/menu-actions")" == "$expected" ]] || fail "recovery option $key called the wrong action"
    for text in 'Create or refresh the preventive recovery snapshot' \
        'Recover or reboot into a stock boot' 'Show detailed recovery status' \
        'Remove the managed recovery snapshot and entry'; do
        contains "$menu_output" "$text" "recovery submenu omitted an action"
    done
done
: > "$work/menu-actions"; stock_recovery_menu <<<b >/dev/null
[[ ! -s "$work/menu-actions" ]] || fail "Back changed recovery state"
: > "$work/menu-actions"; invalid_menu="$(stock_recovery_menu <<<'x
b')"
[[ "$(grep -c 'Stock boot and recovery' <<<"$invalid_menu")" -eq 2 ]] || fail "invalid recovery input did not redraw menu"
[[ ! -s "$work/menu-actions" ]] || fail "invalid recovery input ran an action"

stock_recovery_status() {
    printf 'SNAPSHOT\trefresh-required\nNORMAL_ENTRY\tavailable\nRECOVERY_ENTRY\tlegacy-untrusted\n'
}
refresh_menu="$(stock_recovery_menu <<<b)"
contains "$refresh_menu" 'Preventive snapshot: refresh-required' \
    "recovery menu hid the legacy refresh requirement"
contains "$refresh_menu" 'Managed recovery entry: legacy-untrusted' \
    "recovery menu described a legacy entry as available"
contains "$refresh_menu" 'Legacy refresh-required snapshots are never used' \
    "recovery menu proposed automatic legacy recovery"
contains "$refresh_menu" 'Only a current trusted snapshot can recreate a missing recovery entry' \
    "recovery menu did not describe the trusted-snapshot requirement"

(
    require_supported_machine() { :; }
    ensure_dependencies() { :; }
    refine_installation_formats_cached() { :; }
    status_one() { :; }
    boot_state_label() { printf '%s\n' "${PROBE_STATE:-unknown}"; }
    boot_state_color() { :; }
    probe_boot() {
        PROBE_STATE="$RECOVERY_BOOT"
        PROBE_REVISION='fixture'
        PROBE_REASON='fixture'
    }
    stock_recovery_status() { printf '%b\n' "$RECOVERY_STATUS_OUTPUT"; }

    check_status_summary() {
        local boot="$1" manager_output="$2" expected="$3" output
        RECOVERY_BOOT="$boot"
        RECOVERY_STATUS_OUTPUT="$manager_output"
        output="$(status_variants all)"
        contains "$output" "Stock recovery: $expected" \
            "status all did not report snapshot state $expected during $boot boot"
        if grep -Fq 'Stock recovery: BOOT' <<<"$output"; then
            fail "status all exposed the recovery manager's raw BOOT record"
        fi
    }

    for mode in color no-color plain; do
        case "$mode" in
            color) COLOR_ENABLED=1; PLAIN_MODE=0 ;;
            no-color) COLOR_ENABLED=0; PLAIN_MODE=0 ;;
            plain) COLOR_ENABLED=0; PLAIN_MODE=1 ;;
        esac
        set_palette
        check_status_summary stock \
            $'BOOT\tstock\nSNAPSHOT\tvalid\nNORMAL_ENTRY\tavailable' valid
    done
    COLOR_ENABLED=0
    PLAIN_MODE=0
    set_palette
    check_status_summary combined \
        $'BOOT\tcombined\nSNAPSHOT\tvalid\nNORMAL_ENTRY\tavailable' valid
    check_status_summary stock \
        $'BOOT\tstock\nSNAPSHOT\tmissing\nNORMAL_ENTRY\tavailable' missing
    check_status_summary stock $'UNAVAILABLE\tNot checked' unavailable
    check_status_summary s5 $'BOOT\ts5\nNORMAL_ENTRY\tavailable' unavailable
)

(
    machine_values() { fail "reference dashboard read host DMI"; }
    machine_supported() { return 0; }
    machine_readable() { return 0; }
    collect_missing_dependencies() { MISSING_PACKAGES=(); }
    probe_boot_if_cached() {
        PROBE_STATE=stock
        PROBE_REVISION=0x01072009
        PROBE_CLEAN=1
        PROBE_REASON=fixture
    }
    refine_installation_formats_cached() {
        PROBE_S5_FORMAT=managed
        PROBE_COMBINED_FORMAT=managed
    }
    boot_state_label() { printf 'STOCK / SAFE\n'; }
    boot_state_color() { :; }
    stock_recovery_status() {
        printf 'BOOT\tstock\nSNAPSHOT\tvalid\nNORMAL_ENTRY\tavailable\n'
    }
    variant_dashboard_status() { printf 'CURRENT\n'; }
    variant_dashboard_color() { :; }
    pending_description() { return 1; }

    COLOR_ENABLED=0
    PLAIN_MODE=1
    UNICODE_ENABLED=0
    set_palette
    show_banner >"$work/plain-dashboard.out"
    plain_dashboard="$(<"$work/plain-dashboard.out")"
    contains "$plain_dashboard" 'Stock recovery' "dashboard truncated Stock recovery"
    contains "$plain_dashboard" 'Preventive snapshot' "dashboard truncated Preventive snapshot"
    contains "$plain_dashboard" 'All commands available' "dashboard truncated dependency description"
    normalized_dashboard="$(tr -s ' ' <"$work/plain-dashboard.out")"
    if grep -Fq 'Stock recover Preventive snapshot' <<<"$normalized_dashboard"; then
        fail "dashboard retained the observed truncated Stock recovery label"
    fi
    if grep -Fq 'Dependencies All required command' <<<"$normalized_dashboard"; then
        fail "dashboard retained the observed truncated dependency description"
    fi
    LC_ALL=C grep -q '[^ -~[:space:]]' "$work/plain-dashboard.out" \
        && fail "plain dashboard emitted a non-ASCII character"
    grep -q $'\033' "$work/plain-dashboard.out" \
        && fail "plain dashboard emitted an ANSI escape sequence"
    while IFS= read -r line; do
        [[ -z "$line" || "${#line}" -eq 76 ]] \
            || fail "plain dashboard line width is ${#line}, expected 76"
    done <"$work/plain-dashboard.out"

    PLAIN_MODE=0
    UNICODE_ENABLED=1
    show_banner >"$work/unicode-dashboard.out"
    grep -Fq '╭' "$work/unicode-dashboard.out" \
        || fail "normal dashboard did not render Unicode borders"
    python3 - "$work/unicode-dashboard.out" <<'PY'
from pathlib import Path
import sys

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line and len(line) != 76:
        raise SystemExit(f"Unicode dashboard line width is {len(line)}, expected 76")
PY

    recommendation="$(recommended_action)"
    [[ "$recommendation" == \
        'Managed entries are installed; run status after kernel or initramfs updates.' ]] \
        || fail "installed-entry recommendation is not neutral"
    if grep -Fq 'remove and freshly install each entry' <<<"$recommendation"; then
        fail "installed-entry recommendation still implies immediate intervention"
    fi
)

grep -Fq "printf '  %br.%b Stock boot and recovery" "$ROOT/omen-acpi" || fail "r is not a stable recovery menu entry"
grep -Fq 'r|R) stock_recovery_menu' "$ROOT/omen-acpi" || fail "r does not always open the recovery submenu"
grep -Fq 'p|P) ( pending_workflow_action' "$ROOT/omen-acpi" || fail "pending workflow is not separated as p"
grep -Fq 'Reboot into stock to continue pending' "$ROOT/omen-acpi" || fail "pending reboot label is missing"
grep -Fq 'Resume pending' "$ROOT/omen-acpi" || fail "pending resume label is missing"
grep -Fq 'confirm_dangerous "Create or restore the managed stock recovery entry?' "$ROOT/omen-acpi" \
    || fail "recovery entry creation lacks confirmation"
grep -Fq 'confirm_dangerous "Remove the managed recovery snapshot and entry?' "$ROOT/omen-acpi" \
    || fail "recovery removal lacks confirmation"
grep -Fq "SNAPSHOT\\trefresh-required" "$ROOT/omen-acpi" \
    || fail "frontend does not block automatic recovery from refresh-required snapshots"

for command in prepare-stock-recovery recover-stock reboot-stock remove-stock-recovery resume; do
    OMEN_ACPI_TESTING=1 OMEN_ACPI_SOURCE_ONLY=0 "$ROOT/omen-acpi" --plain --help | grep -Fq "omen-acpi $command" \
        || fail "direct command disappeared: $command"
done

[[ "$ROOT" != /boot* && "$work" == /tmp/* ]] || fail "unsafe test paths"
printf 'interactive menu regressions: PASS\n'
