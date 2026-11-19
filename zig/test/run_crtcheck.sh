#!/bin/bash
# run_crtcheck.sh [N] - compare the Zig runtime's C library (zig/rt: crt.zig, libm.zig, str.zig, fs.zig) with the
# system's glibc, as php/test/run_crtcheck.sh does for the PHP runtime: libm results bit for bit (N cases per
# function plus a grid of special values; tests/crtcheck/libm.c), printf output (printf.c, and pycheck/specs.c for
# every conversion spec the engine's format strings use), sscanf results (scanf.c), from_chars / strtol / strtod /
# atoi / ctime / ctype / get_nprocs (misc.cpp), and unit checks of the rest (crtcheck.zig units). The C and C++
# programs use only the system's own libc, libm and libstdc++; everything is built in W (default
# /dev/shm/zig6_crtcheck) and deleted at the end; tests/ is only read. Set TZ to test ctime in another time zone.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); C=$ROOT/tests/crtcheck
W=${W:-/dev/shm/zig6_crtcheck}; rm -rf "$W"; mkdir -p "$W"
for p in libm printf scanf; do gcc -O2 -ffp-contract=off -fno-builtin -o "$W/$p" "$C/$p.c" -lm; done
gcc -O2 -o "$W/specs" "$C/pycheck/specs.c"
g++ -O2 -std=c++20 -o "$W/misc" "$C/misc.cpp"
"$HERE/build_test.sh" crtcheck.zig "$W/crtcheck"
R="$W/crtcheck"
N=${1:-300000}
"$W/libm" "$N" | $R libm "$N"
"$W/printf" | $R printf
"$W/specs" | $R printf
"$W/scanf" | $R scanf
"$W/misc" | $R misc
$R units
rm -rf "$W"
