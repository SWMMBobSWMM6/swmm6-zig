#!/bin/bash
# run_std_checks.sh - the Zig runtime's libstdc++ behaviour against libstdc++ itself, on the cases of tests/stdcheck
# (as php/test/run_std_checks.sh does for the PHP runtime):
#   sort    sortcheck.zig (modes O, P, I, D) against sortcheck.cpp: the permutations std::sort, std::stable_sort and
#           std::partial_sort leave on keys with many ties, over structs (O), object pointers (P, as the engine sorts
#           its events), ints and doubles ordered through a key table (I, D, as the engine sorts index arrays)
#   hash    hashcheck.zig against hashcheck.cpp: unordered_map / unordered_set bucket counts and iteration order after
#           inserts, operator[], erases, reserve and copies, and std::hash of strings
# (The iostream check of tests/stdcheck/run_stream.sh is not ported, as in the PHP port; the gate exercises the
# engine's stream use.) The C++ programs use only the system's libstdc++. Everything is built in W (default
# /dev/shm/zig6_stdcheck) and deleted at the end; tests/ is only read.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); S=$ROOT/tests/stdcheck
W=${W:-/dev/shm/zig6_stdcheck}; rm -rf "$W"; mkdir -p "$W"
fail=0
same() { if cmp -s "$1" "$2"; then echo "  $3: identical"; else echo "  $3: DIFFERENT"; diff "$1" "$2" | head -6 | cut -c1-300; fail=1; fi; }
g++ -O2 -std=c++20 -o "$W/sortcheck" "$S/sortcheck.cpp"
g++ -O2 -std=c++20 -o "$W/hashcheck" "$S/hashcheck.cpp"
"$HERE/build_test.sh" sortcheck.zig "$W/sortcheck_zig" || exit 1
"$HERE/build_test.sh" hashcheck.zig "$W/hashcheck_zig" || exit 1
"$W/sortcheck" > "$W/sort_cpp.txt"; "$W/hashcheck" > "$W/hash_cpp.txt"
echo "sort cases: $(wc -l < "$W/sort_cpp.txt")"
for m in O P I D; do "$W/sortcheck_zig" $m > "$W/sort_zig_$m.txt"; same "$W/sort_cpp.txt" "$W/sort_zig_$m.txt" "sort, stable_sort, partial_sort ($m), libstdc++ and Zig"; done
"$W/hashcheck_zig" > "$W/hash_zig.txt"
echo "hash lines: $(wc -l < "$W/hash_cpp.txt")"
same "$W/hash_cpp.txt" "$W/hash_zig.txt" "unordered_map / unordered_set order and std::hash, libstdc++ and Zig"
rm -rf "$W"
exit $fail
