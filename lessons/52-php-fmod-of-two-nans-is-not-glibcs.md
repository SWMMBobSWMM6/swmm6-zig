PHP's `fmod` gave `nan` for `fmod(-nan, nan)` where glibc's gives `-nan`: the PHP binary imports glibc's fmod, but its own `fmod()` does not always reach it.

The runtime's `LibM_fmod` called PHP's function:

```php
function LibM_fmod($x, $y) { return \fmod($x, $y); }
```

The C library check (`php/test/run_crtcheck.sh`, which compares with the system's glibc bit for bit) found one case in
300,576:

```
fmod         300576          1         1        0          1  -nan, nan: -nan vs nan
```

glibc's fmod returns `(x * y) / (x * y)` for a NaN operand, which on x86-64 is the first NaN operand, quieted. The
runtime now does the same before calling PHP's:

```php
function LibM_fmod($x, $y) { return $x == $x && $y == $y ? \fmod($x, $y) : ($x != $x ? $x + $x : $y + $y); }
```

PHP 8.3.6 gave `+nan` for both `fmod(-nan, nan)` and `fmod(nan, -nan)` and `-nan` for `fmod(-nan, 1.0)`; the binary
imports `fmod@GLIBC_2.38`, but `objdump -d` finds `fprem` in it, so the C compiler that built PHP evidently expands
fmod inline with the x87 remainder instruction, whose rule for two NaNs is not glibc's. Every other math function the
engine calls matched glibc on every tested argument, NaNs included.
A language's math function being "the C library's" has to be checked per function, NaNs of both signs included.
