# Patch variants

The repository applies deterministic transformations to a DSDT extracted locally
from the target machine. It does not distribute an HP firmware table or a compiled
AML file.

Both variants require the exact original structural anchors from the reference
firmware and fail closed if their expected occurrence counts differ.

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

## `combined`: S5 plus WQBZ buffer bounds

OEM revision: `0x0107200B`

The combined variant includes the complete S5 transformation above and also
changes exactly two loops in `WQBZ`. The original loops test a buffer element
before proving that `Local5` is within the `BF01` buffer:

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
`0x32`-byte buffer. The WQBZ change is independent of the shutdown fix; the
combined variant exists so both corrections can be tested together without
misrepresenting them as one root cause.
