Making a Perl closure copies the pad of the anonymous sub (every lexical and every operator's target), and freeing it frees them all, so a lambda with a 140-line body made on every call cost more than the loop that used it.

The C# engine makes lambdas inside per-step functions; the translator wrote them where C# makes them:

```perl
sub F_outfall_setAllOutfallDepths {
  my ($ctx, $dt_routing) = @_;
  ...
  $_t1 = sub {
    my ($j) = @_;
    my ($_t2, $_t3, ..., $h_blen ...);   # 140 lines follow
    ...
  };
  my $process_outfall = $_t1;
```

The sampling profiler (perl/test/prof.pl) gave 2% of a run to the statement after each call of such a function and
1% to `my $process_outfall = $_t1;`: Perl dispatches signals at the next statement, so the time of making and freeing
the closure shows on the statement after it. A lambda with statements is now lifted into a named sub, and the closure
made in its place only passes it the variables it captures, which the named sub aliases with refaliasing (writes go
back to the caller's variables, as C#'s captured variables do):

```perl
  $_t1 = sub { L_17(@_, $ctx, $nodes, $elapsed_days) };
...
sub L_17 {
  my ($j) = @_;
  my ($_t2, ...);
  \my $ctx = \$_[1];
  \my $nodes = \$_[2];
  \my $elapsed_days = \$_[3];
  ...
```

In Perl, keep the body of a closure that is made often small, and keep in mind that a time sample lands on the
statement after the one that spent it.
