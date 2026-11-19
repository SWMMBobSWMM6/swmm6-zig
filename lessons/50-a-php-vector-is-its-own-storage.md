The PHP runtime keeps a vector's elements in the vector object itself, but the translator printed the C# field `v.a` (a `T[]`) as it prints every array, so `v.a[i]` became `$v->a->a[$i]` and the engine stopped on its first deck.

C# arrays are PHP `Ary` objects whose `->a` is the PHP array. The C# runtime's `Vec<T>` has a field `a` of type
`T[]`, so a range-for over a vector's storage was printed as an element of an array held in a field:

```php
$__r2 = F_transport_reactionSectionTags();
for ($__i3 = 0; $__i3 < $__i3_n; ++$__i3) {
    $tag_2 = $__r2->a->a[$__i3];
```

```
Unhandled exception. ErrorException: Attempt to read property "a" on array
   #1 php/gen/engine.php(99276): DefaultInputPlugin->register_builtin_handlers()
```

The PHP `Vec` has no separate array object: its `->a` is the element array (and `->n` the size), which saves an
object and an indirection on every element access. The translator now prints the field `Vec<T>.a` as the vector
itself (`IsVecStore` in `PhpFn.cs`), so `v.a[i]` is `$v->a[$i]`, `v.a.Length` is `\count($v->a)` and `ref v.a[i]` is
`new ArrRef($v, $i)`; a write to the field would be reported as a TODO (there is none). When the runtime represents a
C# type differently from the general rule, map every way the C# reaches it (fields as well as indexers), not only the
common one; the generated file passed `php -l`, and only running a deck showed the mismatch.
