Perl computes `+`, `-` and `*` on whole-number operands with integers when it can, so `-0.0` disappears: `0.0 * -1.0` is `0`, not `-0.0`, and a `.out` value that C# writes as `-0.0` came out as `+0.0`.

Perl keeps a number as an integer (IV) and a double (NV) at once; `pp_multiply` and `pp_add` use integer arithmetic
when both operands are integer-valued and the result fits. An integer has no sign of zero:

```perl
my ($a, $b) = (0.0, -1.0);
printf "%s\n", unpack('H*', pack('d>', $a * $b));   # 0000000000000000, where C#'s 0.0 * -1.0 is 8000000000000000
my $z = unpack('d>', pack('H*', '8000000000000000'));   # -0.0
printf "%s\n", unpack('H*', pack('d>', $z + $z));       # 0000000000000000; IEEE gives 8000000000000000
```

The translator (tools/cs2x/PlFn.cs, DblArith) now writes every double `+`, `-` and `*` whose result can be a zero
with a repair that costs one `||` when the result is not zero:

```perl
($x + $y) || ((pack('d<', $x) & pack('d<', $y)) eq K_NZB ? K_NZERO : 0.0)          # -0.0 only if both are -0.0
($x - $y) || ((pack('d<', $x) & ~pack('d<', $y)) eq K_NZB ? K_NZERO : 0.0)         # -0.0 - +0.0
($x * $y) || (((pack('d<', $x) ^ pack('d<', $y)) & K_SIGNB) eq K_NZB ? K_NZERO : 0.0)   # signs differ
```

and unary minus as `(-$x || (pack('d<', $x) eq K_NZB ? 0.0 : K_NZERO))`. The repair is skipped where an operand is
a literal or an integer converted to double, which cannot make a negative zero. In Perl, any double operation whose
result can be zero must be checked for the sign of that zero.
