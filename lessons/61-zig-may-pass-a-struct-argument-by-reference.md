Zig may pass a struct argument by reference to the caller's memory, and may make a `const` copy of an array element a reference to it: a function that stores into that memory and then reads the argument sees the new value, in ReleaseFast and not in Debug.

The Zig port's heap sort (`zig/rt/cont.zig`, a port of libstdc++'s `__adjust_heap`) was written as libstdc++ has it:

```zig
fn makeHeap(comptime T: type, a: [*]T, first: i64, last: i64, comp: Cmp(T)) E!void {
    ...
        const value = a[ix(first + parent)];
        try adjustHeap(T, a, first, parent, len, value, comp);
...
fn adjustHeap(comptime T: type, a: [*]T, first: i64, hole0: i64, len: i64, value: T, comp: Cmp(T)) E!void {
    ...
            a[ix(first + hole)] = a[ix(first + (second - 1))];   // overwrites the element value came from
    ...
        while (hole > top and try comp.call(a[ix(first + parent)], value)) {
    ...
    a[ix(first + hole)] = value;
```

On `int`, `double` and pointer elements this is right: they are passed in registers. On a two-field struct
(`tests/stdcheck/sortcheck.cpp`'s `{ key, id }`, run through `zig/test/sortcheck.zig`), `std::partial_sort` of two
elements left `1 1`: `value` was a reference to `a[first + parent]`, the store before the loop changed it, and the
element it stood for was lost. 2,202 of the 6,447 sort cases differed, all of them `partial_sort`; a 40-line program
with the same two functions gives `0 1` built `-O Debug` and `1 1` built `-O ReleaseFast` (Zig 0.15.2). Zig allows a
by-value struct parameter to be passed as a reference to the caller's memory, and a `const` local copied from memory
and then passed on is no protection.

What fixed it was a `var` copy before the first store: `var value = value0; _ = &value;` at the top of `adjustHeap`
(and `var` for the temporaries in `swap`, `insertionSort`, `popHeap`), after which all 6,447 cases match libstdc++ in
the struct, pointer, int and double modes. The same copy went into the runtime's container functions that write into
a container and then read an element argument (`Vec.insert`, `assign`, `resize`, `push_back`). The generated engine
was already safe: the translator copies every parameter into a `var` at function entry, and binds temporaries only to
call results. The engine's own sorts are of pointers, ints, doubles and `u64`, so the gate could not have shown this;
only the runtime check on a struct element type did. When porting code that passes an element of an array to a
function that rearranges the array, copy it into a `var` first.
