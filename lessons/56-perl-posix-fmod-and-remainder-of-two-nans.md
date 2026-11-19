Perl's `POSIX::fmod` and `POSIX::remainder` of two NaNs return the other NaN than glibc's: `fmod(-nan, nan)` was `nan` (glibc: `-nan`, the first) and `remainder(nan, -nan)` was `nan` (glibc: `-nan`, the second).

The runtime called POSIX directly:

```perl
sub LibM_fmod { POSIX::fmod($_[0], $_[1]) }
sub LibM_remainder { POSIX::remainder($_[0], $_[1]) }
```

`perl/test/run_crtcheck.sh` (glibc's results bit for bit) found one case in 300,576 for each:

```
fmod         300576          1         1        0          1  -nan, nan: -nan vs nan
remainder    300576          1         1        0          1  nan, -nan: -nan vs nan
```

A 5 by 5 table of NaNs with payloads, run in C and in Perl, gave the rule: with two NaN operands glibc's fmod returns
the first quieted and its remainder the second; with one, both return that one, as Perl does. POSIX.so imports
`fmod@GLIBC_2.38` and `remainder@GLIBC_2.2.5`, but the compiler that built it evidently does not always reach them.
The runtime now decides the two-NaN case itself:

```perl
sub LibM_fmod { $_[0] != $_[0] && $_[1] != $_[1] ? $_[0] + 0.0 : POSIX::fmod($_[0], $_[1]) }
sub LibM_remainder { $_[0] != $_[0] && $_[1] != $_[1] ? $_[1] + 0.0 : POSIX::remainder($_[0], $_[1]) }
```

As lesson 52 found for PHP: check each math function of a language against glibc with NaNs of both signs.
