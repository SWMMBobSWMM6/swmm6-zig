glibc's `%#g` prints `1.e+06` for 999999.5, not the `1.00000e+06` the C standard asks for: when the number has as many digits before the point as the precision and rounding carries into a new digit, glibc switches to the exponential style and drops the fraction digits.

`tests/crtcheck/printf.c` formats 179,756 cases with the system's glibc 2.39 (`%#g` among them, though the engine's
format strings never use `#`). The Zig port's printf (`zig/rt/crt.zig`, which chooses the style from the exponent
after rounding, as the C standard and the C# runtime's `FormatFloat` do) gave `1.00000e+06` where glibc gave:

```
%#g    999999.5  ->  1.e+06      (C standard: 1.00000e+06)
%#.3g  999.5     ->  1.e+03      (C standard: 1.00e+03)
%#G    999999.5  ->  1.E+06
%#.3g  99999.95  ->  1.00e+05    (no carry across the style choice: as the standard says)
%#g    9.999995  ->  10.0000     (carry, but still the fixed style: as the standard says)
%g     999999.5  ->  1e+06       (without # the zeros go anyway, so the quirk does not show)
```

glibc decides between the fixed and exponential styles from the exponent before rounding. With exponent P-1 it
chooses the fixed style with no fraction digits; when rounding then carries to 10^P it moves to the exponential style
but keeps the fraction-digit count of the fixed style, zero, and `#` adds only the point. The case needs the `#`
flag, a value whose integer part has exactly P digits, and a carry, so no SWMM format meets it; it was matched in the
runtime (`formatFloat`) so that the whole of `printf.c` agrees (the Perl runtime also has 0 differences on it,
`perl/results/crtcheck.txt`). The same run found the runtime's other gaps on conversions the engine does not use, all fixed: the `#`
flag on `%o`, `%x` and `%X`; the `h` and `hh` modifiers (`%hhu` of -1 is 255); a null `%s` prints `(null)` only when
the precision is absent or at least 6, and nothing otherwise; `%020a` puts the zeros after `0x`; and `%.0a` rounds
the leading hex digit half to even (1.5 gives `0x2p+0`). A printf checked only on the engine's own conversions
(`tests/crtcheck/pycheck/specs.c`, 0 differences from the start) can still differ from glibc this way; when the runtime
is meant to be glibc's printf, check it on `printf.c` as well.
