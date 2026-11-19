A Perl `do { ...; ...; e }` block with more than one statement enters and leaves a scope each time it runs, about 60 ns, twice the cost of the expression it computes; a comma expression in scalar context does the same work without it.

The translator wrote C#'s post-increments, min/max with arguments that must be evaluated once, and a division whose
operands must be read once as do blocks:

```perl
my $h1 = do { $_t2 = ...; $_t3 = $z1; $_t2 < $_t3 ? $_t3 : $_t2 };
```

Measured on this machine (perl 5.38.2, minimum of five runs, one million iterations):

```
do { $t1 = $a[$j]; $t2 = $b[$j]; $t1 < $t2 ? $t2 : $t1 }        107 ns
scalar($t1 = $a[$j], $t2 = $b[$j], $t1 < $t2 ? $t2 : $t1)       54 ns
(($t1 = $a[$j]) < ($t2 = $b[$j]) ? $t2 : $t1)                   49 ns
```

They are now written `scalar(..., ..., e)`: `scalar` keeps the comma operator in scalar context, so it also works as
a function argument, where a bare comma list would pass every element. A `do` block with a single expression
(`do { use integer; $x + $y }`) costs little and stays. In generated Perl, prefer expressions to blocks inside
expressions.
