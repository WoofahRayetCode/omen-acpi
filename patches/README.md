# Patch variants

The two variants answer two different questions. The first asks whether the
reference firmware's existing discrete-GPU power-off path can be invoked during
S5 shutdown. The second asks whether two out-of-bounds reads in `WQBZ` can be
prevented while preserving the method's original zero-terminated copy.

The S5 transformation is common to both variants. The WQBZ transformation is
present only in Combined; it is not treated as part of the shutdown root cause.

The repository applies these rules to a DSDT extracted locally from the target
machine. It does not distribute an HP firmware table or a compiled AML file.

Both variants require the exact original structural anchors from the reference
firmware and fail closed if their expected occurrence counts differ.

## The firmware path used by the S5 change

When ACPI prepares an orderly S5 transition, `_PTS` receives `Arg0 == 5`. In the
reference SSDT, `PEGP._PS3()` reaches the GPU power resource only through the
branch guarded by `OMPR == 0x03`. That branch calls `PG00._OFF()`.

The intended sequence is therefore not an arbitrary pair of ACPI operations:

```text
_PTS(5) → OMPR = 3 → PEGP._PS3() → PG00._OFF()
```

The names have distinct roles:

| Name | Role in the reference firmware |
| --- | --- |
| `_PTS(5)` | system method executed while preparing the S5 soft-off state |
| `PEGP` | ACPI device representing the discrete GPU |
| `OMPR` | firmware variable tested by `PEGP._PS3()`; the relevant branch requires `0x03` |
| `PEGP._PS3()` | firmware device-power method that contains the guarded call to the power resource |
| `PG00._OFF()` | power-resource method whose body performs the GPU power-off sequence when its own guards pass |
| `NVDE` | one guard read by `PG00._OFF()`; neither patch variant writes it |

## `s5`: NVIDIA S5 power-off

OEM revision: `0x0107200A`

The S5-only variant extends `_PTS` after the original firmware preparation calls
and only when `Arg0 == 5`. The inserted operations are:

```asl
If (LEqual (Arg0, 0x05))
{
    If (CondRefOf (\_SB.PCI0.GPP0.PEGP.OMPR))
    {
        If (CondRefOf (\_SB.PCI0.GPP0.PEGP._PS3))
        {
            Store (0x03, \_SB.PCI0.GPP0.PEGP.OMPR)
            \_SB.PCI0.GPP0.PEGP._PS3 ()
        }
    }
}
```

This is intentionally identical to the operation sequence in the original
machine-tested standalone installers. It preserves the firmware's `_PS3` guard
and power-resource path, does not write `NVDE`, does not call `PG00._OFF()`
directly, and does not change suspend or runtime power management.

The `CondRefOf` checks preserve the call only when both referenced objects are
available at runtime. Before compilation, the builder separately requires the
exact reference headers, `_PTS` structure and occurrence counts; these runtime
guards are not used as a substitute for structural verification.

## `combined`: S5 plus WQBZ buffer bounds

OEM revision: `0x0107200B`

The combined variant includes the complete S5 transformation above and also
changes exactly two loops in `WQBZ`. The original loops test a buffer element
before proving that `Local5` is within the `BF01` buffer:

- `BF01` is the source buffer;
- `Local5` is the method-local source index;
- `Local1` is the destination index;
- `Local3` holds the current byte before it is stored in `N005`.

They are ordinary AML method-local variables. In particular, `Local5` is not a
register, a pointer stored elsewhere or part of the error message.

```asl
While (LNotEqual (DerefOf (Index (BF01, Local5)), Zero))
{
    Store (DerefOf (Index (BF01, Local5)), Local3)
    Store (Local3, Index (N005, Local1))
    Increment (Local5)
    Increment (Local1)
}
```

The bounded form checks `Local5 < SizeOf(BF01)` first and preserves the original
zero-terminated behaviour:

```asl
While (LLess (Local5, SizeOf (BF01)))
{
    If (LEqual (DerefOf (Index (BF01, Local5)), Zero))
    {
        Break
    }

    Store (DerefOf (Index (BF01, Local5)), Local3)
    Store (Local3, Index (N005, Local1))
    Increment (Local5)
    Increment (Local1)
}
```

This prevents the observed `AE_AML_BUFFER_LIMIT` access at index `0x32` of a
`0x32`-byte buffer: the last valid index is `0x31`. Checking
`Local5 < SizeOf(BF01)` before dereferencing makes the valid range explicit,
while the inner zero test retains the original termination rule. The WQBZ
change is independent of the shutdown fix; the combined variant exists so both
corrections can be tested together without misrepresenting them as one root
cause.

## What the builder proves before packaging

The transformation is accepted only when the source contains the expected
reference header, one target `_PTS` body and exactly two original WQBZ loops in
the `WQBZ` method. The builder then checks that:

1. the S5 operations occur once, inside `_PTS`, and in the required order;
2. S5-only retains the two original WQBZ loops;
3. Combined replaces exactly those two loops and no lookalike outside `WQBZ`;
4. the selected variant and OEM revision agree;
5. `iasl` produces an AML table with the expected header and checksum;
6. decompiling that AML reconstructs the required operations and loop
   semantics.

These are structural and round-trip guarantees about the generated table. The
real-hardware observations and their limits are recorded separately in
[`../docs/validation.md`](../docs/validation.md).
