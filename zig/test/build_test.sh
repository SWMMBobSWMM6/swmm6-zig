#!/bin/sh
# build_test.sh SOURCE OUT - build one of the Zig check programs (crtcheck.zig, libm_check.zig, sortcheck.zig,
# hashcheck.zig) against the engine's runtime (zig/rt, imported as the module "rt") with the engine's flags
# (zig/build.sh: ReleaseFast, the baseline x86-64, -fno-builtin, -fno-compiler-rt, glibc's libm, the Boehm collector).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
cd "$(dirname "$0")/.."
if command -v zig >/dev/null 2>&1; then ZIG=zig; else ZIG="python3 -m ziglang"; fi
CACHE=${ZIG_CACHE:-/dev/shm/zig6_cache}
export ZIG_GLOBAL_CACHE_DIR="$CACHE" ZIG_LOCAL_CACHE_DIR="$CACHE"
LIBGC=${LIBGC:-$(ls /usr/lib/x86_64-linux-gnu/libgc.so.1 /lib/x86_64-linux-gnu/libgc.so.1 2>/dev/null | head -1)}
nice -n 10 $ZIG build-exe -O ReleaseFast -mcpu=x86_64 -fno-builtin -fno-compiler-rt -lc -lm "$LIBGC" \
    --dep rt -Mroot="test/$1" -Mrt=rt/rt.zig -femit-bin="$2"
