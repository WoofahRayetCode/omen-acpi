#!/usr/bin/env bash
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
require_supported_machine() { :; }
require_stock_boot() { printf 'modified\n' >> "$work/actions"; }
guided_output="$(guided_setup <<<2)"
contains "$guided_output" 'Selected setup: Combined' "readable setup selection was not shown"
contains "$(<"$confirmation")" 'Continue with the Combined experimental setup?' "specific confirmation did not follow selection"
[[ ! -e "$work/actions" ]] || fail "negative confirmation allowed a modification"

prepare_stock_recovery() { printf 'recovery-write\n' >> "$work/install-order-actions"; }
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

grep -Fq "printf '  %br.%b Stock boot and recovery" "$ROOT/omen-acpi" || fail "r is not a stable recovery menu entry"
grep -Fq 'r|R) stock_recovery_menu' "$ROOT/omen-acpi" || fail "r does not always open the recovery submenu"
grep -Fq 'p|P) ( pending_workflow_action' "$ROOT/omen-acpi" || fail "pending workflow is not separated as p"
grep -Fq 'Reboot into stock to continue pending' "$ROOT/omen-acpi" || fail "pending reboot label is missing"
grep -Fq 'Resume pending' "$ROOT/omen-acpi" || fail "pending resume label is missing"
grep -Fq 'confirm_dangerous "Create or restore the managed stock recovery entry?' "$ROOT/omen-acpi" \
    || fail "recovery entry creation lacks confirmation"
grep -Fq 'confirm_dangerous "Remove the managed recovery snapshot and entry?' "$ROOT/omen-acpi" \
    || fail "recovery removal lacks confirmation"

for command in prepare-stock-recovery recover-stock reboot-stock remove-stock-recovery resume; do
    OMEN_ACPI_TESTING=1 OMEN_ACPI_SOURCE_ONLY=0 "$ROOT/omen-acpi" --plain --help | grep -Fq "omen-acpi $command" \
        || fail "direct command disappeared: $command"
done

[[ "$ROOT" != /boot* && "$work" == /tmp/* ]] || fail "unsafe test paths"
printf 'interactive menu regressions: PASS\n'
