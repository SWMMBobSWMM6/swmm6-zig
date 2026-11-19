#!/bin/sh
# build.sh - build the Zig SWMM6 engine:  bin/openswmm <input.inp> <report.rpt> [output.out]
# Needs Zig 0.15.2 (pip install ziglang==0.15.2 provides `python3 -m ziglang`; a `zig` on PATH is used first), glibc's
# libm and the Boehm collector (libgc.so.1, Ubuntu package libgc1).
#   -O ReleaseFast   no safety checks (BUILD_MODE=ReleaseSafe builds the checked engine: bounds, overflow, casts)
#   -mcpu=x86_64     the baseline x86-64: no fused multiply-add instruction can appear (objdump -d finds none)
#   -fno-builtin     LLVM keeps every libm call as written (no pow(x,2) -> x*x, pow(2,x) -> exp2(x), no constant
#                    folding with the compiler's own math library)
#   -fno-compiler-rt Zig's compiler-rt carries its own exp, log, log10, sin, cos, tan and floor, which would capture
#                    the engine's calls (SWMM5 lessons/19); without it every libm call is an import from libm.so.6
#   -lc -lm libgc    glibc, glibc's libm (the library the C++ engine calls) and the collector
# The Zig cache and the build go to /dev/shm (ZIG_CACHE); OUT names the output folder (default bin).
# Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
set -e
cd "$(dirname "$0")"
if command -v zig >/dev/null 2>&1; then ZIG=zig; else ZIG="python3 -m ziglang"; fi
CACHE=${ZIG_CACHE:-/dev/shm/zig6_cache}
export ZIG_GLOBAL_CACHE_DIR="$CACHE" ZIG_LOCAL_CACHE_DIR="$CACHE"
LIBGC=${LIBGC:-$(ls /usr/lib/x86_64-linux-gnu/libgc.so.1 /lib/x86_64-linux-gnu/libgc.so.1 2>/dev/null | head -1)}
[ -n "$LIBGC" ] || { echo "build.sh: libgc.so.1 (the Boehm collector) not found" >&2; exit 1; }
OUT=${OUT:-bin}
mkdir -p "$OUT"
MODE=${BUILD_MODE:-ReleaseFast}
EXTRA=""
[ "$MODE" = ReleaseFast ] || EXTRA="-fno-stack-check"
nice -n 10 $ZIG build-exe main.zig -O "$MODE" -mcpu=x86_64 -fno-builtin -fno-compiler-rt $EXTRA -lc -lm "$LIBGC" \
    ${EMIT:--femit-bin=$OUT/openswmm${BIN_SUFFIX:-}} --name openswmm
