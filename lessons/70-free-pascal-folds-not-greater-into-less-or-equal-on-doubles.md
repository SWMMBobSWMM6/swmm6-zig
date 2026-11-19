Free Pascal 3.2.2 compiles `not (x > y)` on doubles as `x <= y`, at -O- and -O2 alike, which is false for a NaN where C# and C++ give true; the translator writes C#'s `!` as the inline call `NotB(...)`, which it does not fold.

The PHP port met the same rewrite in PHP's optimiser (lesson 58). Here it is the compiler's node simplification, so `-O-`
does not avoid it. A test program (masked floating-point exceptions, `x` a quiet NaN, `y = 1`):

```pascal
b := not (x > Z);                                  // FALSE (C#: true)
b := (x > Z) = False;                              // FALSE
b := (x > Z) xor True;                             // FALSE
if not (x >= y) then Write('A') else Write('a');   // a
repeat ... until not (x < y);                      // never ends on the NaN
b := NotB(x > Z);                                  // TRUE  (function NotB(b: Boolean): Boolean; inline)
b := not ((x > Z) and (y > Z));                    // TRUE  (no De Morgan)
```

It showed on the extra deck `ppr_custom_nan.inp`: a CUSTOM cross-section with a NaN full depth reaches
`XsectEval.lookup`, whose first line is `if (!(x > 0.0)) return table[0];`. Translated as `if (not (x > K_0)) then`,
the NaN fell through to `lookup_exact`, whose `(int)(x / delta)` is INT_MIN, and the table read at that index ended the
run with an access violation (the reference stops on two input errors). The translator now writes C#'s `!` as
`NotB(e)`, the loop exits it makes as `if NotB(cond) then break;` and `until NotB(cond)`, and a Boolean `==`, `!=` or
`^` as `BEq`, `BNe`, `BXor` (`tools/cs2x/PasExpr.cs`, `PasFn.cs`; the functions in `pascal/cpprt`). Equality is not
affected: `NaN = NaN` is false and `NaN <> NaN` true, as in C#.
