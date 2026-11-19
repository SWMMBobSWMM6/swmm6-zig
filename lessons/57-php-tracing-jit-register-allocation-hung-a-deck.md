PHP 8.3.6's tracing JIT with its register allocator (`opcache.jit=tracing`, which is 1254) miscompiled the reaction integrator's adaptive step loop on one extra deck, which then never ended; the same engine finishes it in 0.3 s, byte-identical, with the JIT off, with the function JIT, and with the tracing JIT without register allocation (1054).

The deck (`swmm6-rust/gate/decks/initqual/initq_rxlid_nodes.inp`; the C++ takes 0.06 s) passed every check without
OPcache, and the 447 corpus models gated before it passed with the tracing JIT. In the gate it ran for 13 minutes at
full CPU before it was stopped. A backtrace taken with SIGALRM under the same settings showed where it was:

```
{closure} @177763
__get @170040
F_transport__anon_..._ReactionIntegrator_cpp_errNorm_ReactionIntegrator @132152
transport_ReactionIntegrator_step__rReactionData_..._RxRateContext @161459
F_msxlid_reactPool @161296
```

`step` is the embedded Runge-Kutta loop: it shrinks `h` until the error norm `errNorm(...)` is at most 1.0, then
accepts the step:

```php
$en = F_transport__anon_..._errNorm_ReactionIntegrator($rx, Ptr_op_Add_PtrT_l($ridx->data(), $gb), $gn, $ws->ytmp_->data(), $ws->err_->data());
if ($en <= 1.0) {
    ...
    $accepted = true;
```

With the tracing JIT's register allocation the loop never accepted. One setting at a time on that deck:

```
opcache.jit=off        rc=0  .out identical
opcache.jit=function   rc=0  .out identical   (twice the time of tracing)
opcache.jit=1254       timed out              (tracing, global register allocation)
opcache.jit=1154       timed out              (tracing, local register allocation)
opcache.jit=1252       crashed (rc 134)
opcache.jit=1054       rc=0  .out identical   (tracing, no register allocation)
```

1054 runs as fast as 1254 on the corpus decks timed (4.4 s against 4.5 s, 8.8 s against 8.3 s), so `php/runswmm6` now
uses it, the runtime checks were run again with it (no differences), and the gate chunks after the change ran it.
The miscompiled trace was not narrowed further. A JIT is part of the toolchain under test: a deck that hangs or a
result that changes with the JIT settings is checked with the JIT off before the translator or runtime is blamed.
