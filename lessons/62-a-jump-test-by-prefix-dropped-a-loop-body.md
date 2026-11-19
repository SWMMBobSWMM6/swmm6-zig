A translator that drops the code after a jump (Zig rejects unreachable code) must recognise the jump by its keyword, not by a prefix: `breakdown = ...` starts with `break`, and the rest of a GMRES loop body was silently left out.

The Zig back end (`tools/cs2x/ZigFn.cs`) stops a block after a statement that jumps, because Zig refuses code after
`return`, `break` or `continue`. Its test looked at the start of the last line written:

```csharp
static bool EndsInJump(List<string> lines)
{
    ...
    return s.StartsWith("return ") || s == "return;" || s.StartsWith("break") || s.StartsWith("continue") || s == "unreachable;";
}
```

In `NativeGmres::solve` (`cs/gen/hydraulics_fv_NativeGmres.cpp.cs`) the Arnoldi loop sets a local named `breakdown`
and goes on with the Hessenberg column, the Givens rotations, `++result.iterations` and the convergence test:

```csharp
breakdown = (after <= ((((double)64) * 2.220446049250313E-16) * before));
_ = (((global::Gen.FN99)h)((j + ((ulong)1))) = after);
...
++result.iterations;
...
```

The Zig engine ended the loop body at `breakdown = (after <= ...);`. It compiled (the variables it left unused were
already marked used with `_ = &x;`), it reported no untranslated construct (`zig/cs2zig_todo.txt` was empty), and 480 of
480 corpus models passed, because no corpus model reaches the finite-volume GMRES with a residual it must iterate on.
Three of the 452 extra decks (`sdm_fv_o1.inp`, `sdm_fv_o2.inp`, `sdm_fv_o2_superbee.inp`, run `zig6_x01`) did: at step
193 GMRES returned "breakdown" after zero iterations, and the engine stopped with "FV conservative scalar transfer did
not converge". Instrumenting the scratch copy's early returns found the GMRES exit in two builds (3.5 minutes each);
reading the generated loop against the C# found the missing 46 lines.

The fix tests the keyword: `s == "break;" || s.StartsWith("break :") || s == "continue;" || s.StartsWith("continue :")`.
Regenerating changed only that loop (a `diff` of the old and new `engine.zig` showed one hunk of 46 added lines), and
`grep -E "^\s*(break|continue)[A-Za-z_0-9]"` finds no other statement of the kind. When a translator decides by the
text it has written, match whole tokens, and diff the whole output after any change to such a rule.
