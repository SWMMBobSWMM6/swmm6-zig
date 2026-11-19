PHP's class, function and method names ignore case, so names that C# and every earlier port kept apart (`assign` and `Assign`, a field `F` and a field `f`) collided, and PHP refused to load the engine.

The translator names a reference to an engine field after the field (`FR_<Type>_<field>`), as the Ruby back end does.
`CurveNumState` has two fields, `F` and `f`, and PHP stopped before running a line:

```php
final class FR_CurveNumState_F extends Ref { ... }
final class FR_CurveNumState_f extends Ref { ... }
```

```
PHP Fatal error:  Cannot declare class FR_CurveNumState_f, because the name is already in use in php/gen/engine.php on line 172552
```

The same rule had already stopped the runtime: the C# runtime's `Str` has both `assign(...)` (std::string's) and
`Assign(...)` (the C# port's own), and `Array.Fill` / `File.Exists` are PHP's `array_fill` / `file_exists`:

```
PHP Fatal error:  Cannot redeclare Str::assign_Str()
PHP Fatal error:  Cannot redeclare Array_Fill()
```

Now a lower-case runtime member that matches an upper-case member of the same type case-insensitively is called
`lc_<name>`, a field that differs from another only in case gets a numbered reference class (`FR_CurveNumState_f_1`),
C#'s `Array.Fill` and `File.Exists` are `Cs_Array_Fill` and `Cs_File_Exists`, and the translator checks every name it
writes against the others and PHP's own classes (`tools/cs2x/PhpBuiltins.cs`) ignoring case. Field and variable names
are case-sensitive in PHP and were left alone. Before porting to a language, check which of its namespaces fold case;
`php -l` does not report these collisions, only loading the file does.
