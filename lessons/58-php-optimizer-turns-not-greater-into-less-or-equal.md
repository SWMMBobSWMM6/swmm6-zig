PHP 8.3.6's OPcache optimizer (pass 5, the CFG block pass) compiled `if (!($x > 0.0))` as `IS_SMALLER_OR_EQUAL $x, 0.0`, which is false for a NaN where the C# test is true, so a NaN depth went on to an array index of int.MinValue and the engine stopped with an exception the C++ never raises.

The extra deck `swmm6-rust/gate/decks/ppr_custom_nan.inp` gives CUSTOM cross sections a depth of `nan`. The C++, the
C# and every other port stop it with ERROR 141 and 145 and exit code 5. The PHP engine stopped instead, in
`SWMMEngine::initialize`:

```
Unhandled exception. ErrorException: Undefined array key -2147483648
   #1 php/gen/engine.php(140072): Ptr->get_Item_i()
   #2 php/gen/engine.php(58260): F_xsect_lookup_exact()
   #3 php/gen/engine.php(59037): xsect_XsectEval->lookup()
```

The translated method guards against a NaN exactly as the C# does:

```php
function lookup($x, $table, $n_items)
{
    if (!($x > 0.0)) {
        return $table->get_Item_i(0);
    }
```

Without OPcache the deck gave the reference's report and exit code. With OPcache (JIT off), the optimizer's dump
(`opcache.opt_debug_level=0x20000`) shows the negated comparison turned into its "opposite":

```
0003 T3 = IS_SMALLER_OR_EQUAL CV0($x) float(0)
0004 JMPZ T3 0009
```

`!(x > 0)` and `x <= 0` differ only for a NaN, and that is the case the guard exists for. Switching the optimizer's
passes off one bit at a time, only bit 0x10 (pass 5) mattered; `php/runswmm6` now runs with
`opcache.optimization_level=0x7FFEBF6F` (passes 5 and 8, SCCP, off; SCCP was already off for 0.0 and -0.0, the SWMM5
PHP port's lesson 32), which costs about 5% on the decks timed. The checks were run again with it. A small script with
the same method did not always reproduce the wrong branch, so whether a given negation is miscompiled depends on more
than the source line; the setting is the fix, not a rewrite of the guards. A translation that relies on NaN-aware
comparisons must be run with an optimizer that keeps them, and the ports' NaN decks are the test for it.
