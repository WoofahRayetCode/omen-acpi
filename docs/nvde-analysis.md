# `NVDE` analysis — HP OMEN 16-ap0xxx / 8E35 / BIOS F.13

Question: does writing `NVDE = 1` during `_PTS`, before `OMPR = 3` and
`_PS3()`, have any effect on the shutdown path?

**Answer: yes, but writing it is unnecessary.** `NVDE` is the guard condition of
the very method the patch invokes to power the GPU down, so it is relevant, and
an earlier revision of this document — based on the DSDT alone — was wrong to
call it inert. However the NVIDIA driver already sets it in every condition that
matters, including after resume (measured, see section 5). The two variants
shipped in 2.1.9 are correct as they are.

Tool: [`nvde-audit.py`](nvde-audit.py). Sources: `dsdt.dsl` (23,227 lines, 614
methods) **and the 23 SSDTs** from the same collection.

## 0. Why the earlier conclusion was wrong

The analysis had been done on the DSDT alone. The DSDT declares as `External`
the methods that live in the SSDTs, and `nvde-audit.py` resolves calls by
four-character short name without accounting for scope. Two consequences:

| Effect | Consequence for the analysis |
|---|---|
| `_PS3` is defined 14 times in the DSDT (USB/PCIe ports) | the call `\_SB.PCI0.GPP0.PEGP._PS3 ()` was resolved against an arbitrary, harmless body |
| the real `PEGP._PS3` lives in `ssdt10` | its body was never read |

The tool now reports both cases (`BLIND SPOTS`, `AMBIGUOUS NAMES`) and refuses
to declare a conclusion closed when it is not.

## 1. What `NVDE` is

DSDT line 219:

```asl
Name (NVDE, Zero)
```

`ssdt10` line 212 imports it:

```asl
External (NVDE, UnknownObj)
```

It is a global namespace variable, not an `OperationRegion` field. Writing it
touches no EC, SMI or register: it matters only because other AML methods read
it back. The point is that they do, and in the worst possible place.

## 2. The real shutdown chain

The S5 patch adds this to `_PTS(5)`:

```asl
Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)
\_SB.PCI0.GPP0.PEGP._PS3 ()
```

`OMPR` is declared in `ssdt10` line 714 (`Name (OMPR, 0x02)`, scope
`\_SB.PCI0.GPP0.PEGP`). The real `PEGP._PS3` is at `ssdt10` line 761:

```asl
Method (_PS3, 0, NotSerialized)
{
    If ((OMPR == 0x03))
    {
        If ((GPRF != One))
        {
            VGAB = VGAR
        }

        \_SB.PCI0.GPP0.PG00._OFF ()
        DGPS = One
        OMPR = 0x02
    }

    _PSC = 0x03
}
```

`PG00` is the GPU's power resource (`ssdt10` line 555, scope
`\_SB.PCI0.GPP0`). Its `_OFF` (line 622) begins like this:

```asl
Method (_OFF, 0, Serialized)
{
    If ((NVDE != One))
    {
        Return (Zero)
    }

    If ((GSTA () != One))
    {
        Return (Zero)
    }
    ...
}
```

The complete chain:

```text
_PTS(5) → OMPR = 3 → PEGP._PS3() → PG00._OFF() → If (NVDE != 1) Return
```

**With `NVDE != 1` the GPU is not powered down.** The same guard is present in
`PG00._ON` (line 569).

## 3. Who writes `NVDE`

| Table | Line | Method | Operation |
|---|---|---|---|
| dsdt | 22900 | `WAK` | `NVDE = Zero` on resume from S3/S4 |
| ssdt10 | 1032 | `PEGP._DSM` | `NVDE = One` (GUID `d4a50b75-…`, → `NBCI`) |
| ssdt10 | 1038 | `PEGP._DSM` | `NVDE = One` (GUID `a3132d01-…`, → `_GPS`) |
| ssdt10 | 1044 | `PEGP._DSM` | `NVDE = One` (GUID `cbeca351-…`, → `NVJT`) |
| ssdt10 | 1050 | `PEGP._DSM` | `NVDE = One` (GUID `a486d8f8-…`, → `NVOP`) |

These are the four standard NVIDIA Optimus `_DSM` GUIDs, invoked by the NVIDIA
driver. Therefore:

- the firmware **does** set `NVDE = 1`, contrary to the earlier claim;
- the DSDT's `If ((NVDE == One))` branches are **not** dead code;
- with the NVIDIA driver loaded, `NVDE` is normally 1 at shutdown, which is why
  the minimal patch works without writing `NVDE`.

Note that `WAK` is not where the reset appears by name: `_WAK` (DSDT line 4057)
calls the helper `WAK`, which performs the write.

## 4. Who reads `NVDE`

| Table | Line | Method | Reachable from patched `_PTS` |
|---|---|---|---|
| ssdt10 | 622 | `PG00._OFF` | **yes**, via `_PS3` |
| ssdt10 | 569 | `PG00._ON` | no |
| dsdt | 13296, 13317 | `GM22` | no (WMI dispatch from the operating system) |
| dsdt | 21956 | `_Q8D` | no (asynchronous EC query) |

## 5. The suspected failure case, measured: it does not occur

`WAK` clears `NVDE` on resume from S3 (`Arg0 == 0x03`) and S4 (`0x04`). If the
driver did not re-issue any of the four `_DSM` calls before shutdown, `NVDE`
would stay `0`, `PG00._OFF()` would return immediately, and the S5 patch would
have no effect at all.

**Measured on 2026-08-01: this does not happen.** The driver re-arms `NVDE` by
itself, about 1.3 seconds after resume.

### Method

The firmware instruments itself. `_GPS` is defined exactly once (`ssdt10` line
1270) and called from exactly one place, `ssdt10` line 1039:

```asl
If ((Arg0 == ToUUID ("a3132d01-8cda-49ba-a52e-bc9d46df6b81")))
{
    NVDE = One
    Return (\_SB.PCI0.GPP0.PEGP._GPS (Arg0, Arg1, Arg2, Arg3))
}
```

`_GPS` begins with `Store ("------- NV GPS DSM --------", Debug)`. Because the
only way into `_GPS` runs through the line that writes `NVDE = One`, seeing that
string in the kernel log **is** proof that `NVDE` has just been set to 1. The
kernel routes AML `Debug` stores into `dmesg` through
`/sys/module/acpi/parameters/aml_debug_output`.

ACPI method tracing (`trace_method_name` plus `trace_state`) was tried first and
produces no output on this kernel, not even for a control method that certainly
runs, such as `\_SB.BAT0._BST`. Do not use it.

### Data

```text
[ 3637.540856] ACPI Debug:  "HP WMI Command 0x04 (BIOS Read)"      ← resume
[ 3638.798096] ACPI Debug:  "------- NV GPS DSM --------"          ← NVDE = One
[ 3638.798157] ACPI Debug:  "GPS fun 19"
[ 3638.798784] ACPI Debug:  "------- NV GPS DSM --------"
[ 3638.798827] ACPI Debug:  "GPS fun 18"
[ 3638.798988] ACPI Debug:  "------- NV GPS DSM --------"
[ 3638.799063] ACPI Debug:  "   GPS fun 42"
[ 3639.845830] ACPI Debug:  "------- NVPCF DSM --------"
```

Three `_GPS` calls 1.26 s after resume, with no interaction with the discrete
GPU. `NVPCF` is a separate `_DSM` and does not touch `NVDE`.

### What the measurement does not cover

- It holds while the proprietary NVIDIA driver is loaded. Without it nothing
  sets `NVDE`, and `PG00._OFF()` powers nothing down.
- A shutdown started within roughly 1.3 s of resume would fall before the
  re-arm; unrealistic with `systemctl poweroff`.
- Measured on S3. Hibernation (S4) goes through the same `WAK`, but was not
  observed directly.

## 6. Conclusion

Two distinct results, and they should be kept apart.

**On the analysis:** `NVDE` is not inert. The earlier document was wrong.
`NVDE = 1` in the old combined variant armed exactly the guard that enables
`PG00._OFF`, the method the patch invokes to power the GPU down. Removing it in
2.1.6/2.1.7 was not a neutral simplification: it made the correction dependent
on whoever sets `NVDE`.

**In practice:** that dependency is satisfied. The NVIDIA driver re-arms `NVDE`
on every resume in about a second, as measured in section 5. Even the one
scenario in which the minimal patch could have stayed inert does not arise.

**Recommendation: do not add a third variant.** The two variants in 2.1.9 are
correct as they are. Reintroducing `NVDE = 1` would make the patch self-
sufficient on paper, but would buy a margin that is not needed while paying a
real cost: between `_PTS(5)` and the actual power-off, `NVDE = 1` makes the
branches in `_Q8D` (EC event `0x8D`) and `GM22` (WMI command `20008h` type
`0x20`) executable, and neither has ever been exercised in that window.

It should also be noted that `NVDE = 1` would not be sufficient on its own:
`PG00._OFF` has a second guard, `If ((GSTA () != One)) { Return (Zero) }`.
Forcing `NVDE` makes the patch self-sufficient, not unconditional.

This conclusion must be revisited if its premise changes: a different or absent
NVIDIA driver, or a BIOS update that modifies `ssdt10`. In that case repeat the
measurement in section 5 before relying on it.

## 7. Reproducing

```bash
./nvde-audit.py --self-test
./nvde-audit.py ~/omen-*acpi-source-*.tar.gz
./nvde-audit.py --scan-all DIRECTORY_WITH_ALL_DSL_FILES
./nvde-audit.py --symbol OMPR --scan-all DIRECTORY_WITH_ALL_DSL_FILES
```

The archive produced by `omen-acpi collect` contains only `dsdt.dsl`. To obtain
the SSDTs as well, decompile the `acpixtract` `.dat` files individually:

```bash
for f in ssdt*.dat; do iasl -d "$f"; done
```

To repeat the measurement in section 5:

```bash
echo 1 | sudo tee /sys/module/acpi/parameters/aml_debug_output
echo "=== RESUME-TEST ===" | sudo tee /dev/kmsg
systemctl suspend
# resume, then wait a minute without touching the discrete GPU
sudo dmesg | sed -n '/RESUME-TEST/,$p' | grep -i 'ACPI Debug'
echo 0 | sudo tee /sys/module/acpi/parameters/aml_debug_output
```

Look for `------- NV GPS DSM --------`, `<<< NBCI >>>`, `<<< NVOP >>>` or
`------- NV JT DSM --------`: these are the four `_DSM` handlers that write
`NVDE = One`. `------- NVPCF DSM --------` does not count; it does not touch
`NVDE`.
