In PHP 8 a warning silenced with `@` still reaches a handler installed with `set_error_handler`, so a handler that turns every warning into an exception made the runtime's `@fopen` of a missing file throw instead of returning NULL.

The PHP engine turns every warning into an exception, so that nothing fails quietly. The runtime opens files with
`@\fopen(...)` and returns NULL on failure, as C's fopen does. The test program's handler threw for every warning:

```php
// php/test/crtcheck.php (first version)
set_error_handler(function ($no, $str, $file, $line) { throw new ErrorException($str, 0, $no, $file, $line); });
```

```
PHP Fatal error:  Uncaught ErrorException: fopen(/tmp/php6_crtcheck_19851/none): Failed to open stream: No such file or directory in php/cpp/crt.php:1362
#2 php/test/crtcheck.php(321): R_fopen()
```

`@` only lowers `error_reporting()` for the call; the handler must check it and decline what was silenced:

```php
set_error_handler(function ($no, $str, $file, $line) {
    if (!(error_reporting() & $no)) return false;
    throw new ErrorException($str, 0, $no, $file, $line);
});
```

The engine's command line (`php/runswmm6.php`) had the check from the start, and the gate runs used it; the two test
programs did not, and the unit check of fopen on a missing file found it. Any harness that runs the runtime must
install the same handler as the engine.
