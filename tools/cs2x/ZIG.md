# C# to Zig: how tools/cs2x/Cs2Zig.cs maps the generated engine

The Zig engine is written from the verified C# engine (`cs/gen`, 480/480 against the SWMM6 reference) by a translator
written for it: Roslyn's semantic model, one IOperation tree per method, printed as Zig 0.15.2. It is a new back end
(`Cs2Zig.cs` for the driver and names, `ZigTypes.cs` for types, hierarchy and declarations, `ZigFn.cs` for statements,
`ZigExpr.cs` for expressions; 2,523 lines), not a copy of another port's; the runtime (`zig/rt`) is written in Zig for
this port, with the C library's printf, strtod and stdio carried over from the SWMM5 Zig port.

    tools/cs2x/build_zig.sh && dotnet tools/cs2x/bin/cs2zig.dll cs zig/gen

writes `zig/gen/engine.zig` (one file, 240,507 lines), `zig/cs2zig_runtime.txt` (every runtime member the engine
uses, with the Zig name it became: 475) and `zig/cs2zig_todo.txt` (untranslated constructs: none). It reads `cs/gen`
and the engine's hand-written partial classes `cs/runtime/Hand_*.cs`; the rest of `cs/runtime` is read for its types
only. `zig/make_primes.sh` writes `zig/rt/primes.zig` (libstdc++'s bucket counts) from `cs/runtime/PrimeList.cs`.

## Output

- One file. The engine's classes are structs; a class is held as an optional pointer `?*T_<ns>_<name>`, so a C#
  reference is a Zig pointer and `null` is `null`. Names: types `T_` + namespace (without `openswmm`) + nesting;
  functions `<Type>__<method>`, free functions `F_<ns>__<name>`, with `__` and type codes appended to an overloaded
  method (the codes of the Go and Fortran ports: `i`, `d`, `Str`, `PtrT`...); static fields `G_<Type>__<name>`,
  set in C#'s order by one function, `__static_init`, which `main.zig` calls first. Zig keywords and names that look
  like Zig's integer types (`i00`, `u8`) are renamed.
- Inheritance: a derived struct's first field is its base, `__base`; the root of a hierarchy has a type id `__tid`
  (numbered from 1000 in the order of the sorted type names). An upcast is `&x.__base`; a downcast is
  `@fieldParentPtr("__base", p)` with `@alignCast`, after a check on the type id where C# checks. `__tid_parent` and
  `__isA` are the generated tables for `is`, `as` and catch clauses.
- Virtual calls: each root virtual method gets a dispatcher `<method>__v` that switches on the type id and calls the
  override; a class with no type id (no derived classes) is called directly.
- Constructors: `<Type>__raw()` allocates the struct, zeroed (the C# defaults), and sets the type id; `<Type>__new...`
  runs the C# constructor body on it. The runtime's protocol functions (`__new`, `__clone`, `__assign`, `__moveFrom`,
  `__dispose`, `__hashOf`) are declared on the structs that need them, so containers copy and hash engine objects as
  the C# runtime does.

## Values

- `double`, `float`, the integer types, `bool`: Zig's `f64`, `f32`, `i32`... `+ - *` on integers are the wrapping
  operators `+% -% *%` (C# is unchecked); `/` and `%` are `@divTrunc` and `@rem`; `%` on doubles is glibc's `fmod`;
  shifts mask the count as C# does (`rt.shl`, `rt.shr`, `rt.ushr`). Conversions are written out as C# does them:
  `rt.f2i32` and its kin for double to integer (as x86-64's `cvttsd2si`, which .NET 8 uses: NaN and out-of-range
  values give the type's minimum), `@floatFromInt`,
  `@floatCast`, `@truncate` and `@bitCast` for the integer ones.
- Float literals are written in decimal when the decimal text reads back to the same double, otherwise as their bit
  pattern; NaN and -0.0 are bit patterns.
- Arrays are `?[]T` (a slice: pointer and length; `null` for a null array); `string` is `?[]const u8`; `object` is
  `rt.Obj` (`?*anyopaque`), with boxing by `rt.box` and unboxing by `rt.unbox`. The runtime's pointer types: `CPtr` is
  `?[*]u8` (a C string or buffer, with an 8-byte length header before a buffer the runtime allocates), `Ptr<T>` is
  `?[*]T`, an iterator `Iter<T>` is `rt.Iter(T)` (base and index, as the C# has it). `ref` parameters and locals are
  `*T`.
- Enums are integer type aliases with one constant per member.

## Statements

- Every engine function returns `E!T` (`rt.E = error{Throw}`) and every call is `try`'d, because almost any C#
  method can throw. A throw stores the exception object (`rt.setExc`) and returns `error.Throw`; `try`/`catch`/
  `finally` become labelled blocks with a state variable (1 for an exception, 2 for a return passing through a
  `finally`), and a catch clause tests the stored object's type id. The C++ standard exceptions are runtime kinds
  1 to 13 (`std::exception` to `bad_variant_access`), .NET's from 100.
- Locals are `var` with `_ = &x;` after them (Zig rejects an unused or never-written `var`); parameters are copied
  into locals at entry. Code after a jump is dropped (Zig rejects unreachable code) and a non-void function ends in
  `unreachable;`. Block labels nothing jumps to are removed.
- Lambdas become top-level functions `__lamN(ctx, ...)`; their context is a struct of `this` and pointers to the
  captured variables, which live in heap cells (`rt.cell`) so the lambda and the method share them. A delegate is a
  runtime struct `rt.FnK(params..., Ret)` of a context and a function pointer, called with `.call(...)`; a method
  group becomes a thunk.
- `goto` (one function, the UEB reference snow model) becomes a loop over a `switch` on a program counter, with the
  function's locals hoisted above it.
- `foreach` over a runtime container is a `while (it.next()) |x|` loop with the value copied into the loop variable.

## Memory

The runtime allocates with the Boehm collector (the system's `libgc.so.1`): `GC_malloc` for structs that hold
pointers and `GC_malloc_atomic` for ones that do not, both zero-filled, interior pointers recognised. Nothing is freed
by hand. C#'s `Dispose` and the C++ destructors the engine relies on for output (closing files) are run where the C#
runs them.

## Aliasing

Zig may pass a struct argument by reference to the caller's memory. A function that writes into memory an argument
came from and reads the argument afterwards then sees the new value: the runtime's heap sort, given a `const` copy of
an array element, duplicated elements when the elements were structs (`../../lessons/61`). Generated
functions copy every parameter into a `var` before their first statement; the runtime's generic functions that write
into a container copy their element arguments first.
