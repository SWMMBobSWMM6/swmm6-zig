Free Pascal evaluates the arguments of a call right to left, so a translation that writes C#'s `f(a(), b())` as `f(a(), b())` runs `b()` first.

C# (and the C++ the C# came from, as compiled for the reference) evaluates arguments left to right. Free Pascal 3.2.2 on
x86-64 evaluates them right to left, for every calling convention; the operands of a binary operator, a receiver and an
assignment's target are evaluated left to right. A test program (built with `fpc -O2`):

```pascal
function A: Int32; begin Write('a'); Result := 1; end;
function B: Int32; begin Write('b'); Result := 2; end;
procedure F(x, y: Int32); begin end;
begin
  F(A, B);        // prints "ba"
  WriteLn(A + B); // prints "ab3"
end.
```

So the translator (`tools/cs2x/PasExpr.cs`, `Seq` with `rtl`) evaluates into temporaries, in C#'s order, every argument
that has a side effect or reads something another argument writes, whenever a call has two or more such arguments.
Arithmetic the translator writes as a call also counts: `ulong` addition is `UAdd64(l, r)` (so that it wraps in the
checked build too) and `double %` is `c_fmod(l, r)`, and their operands are sequenced as a call's; and `x op= y` takes
x's value before y is evaluated when y can change things. Pure arguments (locals, fields, constants) are left in place,
so the generated code has few temporaries.
