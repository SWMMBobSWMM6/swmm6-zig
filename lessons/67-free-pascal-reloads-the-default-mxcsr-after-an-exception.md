Free Pascal reloads its default MXCSR (floating-point exceptions unmasked) whenever it handles an exception, so masking the exceptions with `SetMXCSR` at start-up lasts only until the engine's first `try ... except`.

C's floating-point environment has every exception masked: `0.0 / 0.0` is a NaN. Free Pascal starts with the invalid,
divide-by-zero and overflow exceptions unmasked, and its run-time library resets the SSE control register to
`DefaultMXCSR` (and the x87 one to `Default8087CW`) when it handles an exception. The runtime first did only:

```pascal
initialization
  SetMXCSR($1F80);
```

and the first smoke runs ended with `EInvalidOp` in `UpdateStatistics`, at a `TernD(y_full > 0, d / y_full, 0)`
evaluated with `y_full = 0` (both arms are evaluated; the C++ computes the NaN and discards it), after the input parser
had thrown and caught one of its own exceptions. The fix sets the defaults too (`pascal/cpprt/cpprt.pas`):

```pascal
  DefaultMXCSR := $1F80;
  Default8087CW := $037F;
  SetMXCSR($1F80);
  Set8087CW($037F);
```
