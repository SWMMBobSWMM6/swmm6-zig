#!/bin/bash
# rerun_build.sh [COMMIT] [DIR] - the first half of the independent rerun: a clean copy of COMMIT (default HEAD) of
# this repository (git archive) in DIR (default /dev/shm/zig6_v), where the translator is rebuilt, the engine is
# regenerated from cs/gen and compared byte for byte with the committed zig/gen/engine.zig (and the translator's two
# reports with the committed zig/cs2zig_*.txt), the one generated runtime file (zig/rt/primes.zig) is written again by
# zig/make_primes.sh and compared, and the engine is built there with an empty Zig cache of its own. The gate then runs
# that copy's engine:
#   zig/gate/run_chunk.sh zig6_v1 corpus - DIR/zig/runswmm6_saves.sh   (and zig6_vx, extra)
# After php/gate/rerun_build.sh. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
K=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$K/.." && pwd)
C=${1:-HEAD}; R=${2:-/dev/shm/zig6_v}
rm -rf "$R"; mkdir -p "$R"
git -C "$ROOT" archive "$C" | tar -x -C "$R"
echo "== clean copy of $(git -C "$ROOT" rev-parse --short "$C") in $R"
cd "$R"
echo "== the translator: tools/cs2x/build_zig.sh"
nice -n 10 tools/cs2x/build_zig.sh 2>&1 | grep -v 'warning CS' || true
echo "== the engine, regenerated from cs/gen into $R/regen and compared with zig/gen/engine.zig and zig/cs2zig_*.txt"
mkdir -p "$R/regen/gen"
nice -n 10 dotnet tools/cs2x/bin/cs2zig.dll cs "$R/regen/gen"
for f in gen/engine.zig cs2zig_runtime.txt cs2zig_todo.txt; do
	if cmp -s "$R/regen/$f" "zig/$f"; then echo "zig/$f: $(wc -l < "zig/$f") lines, byte-identical to the commit"; else echo "zig/$f: DIFFERENT"; exit 1; fi
done
echo "== the generated runtime file, written again by zig/make_primes.sh"
zig/make_primes.sh "$R/regen/primes.zig"
if cmp -s "$R/regen/primes.zig" zig/rt/primes.zig; then echo "zig/rt/primes.zig: byte-identical to the commit"; else echo "primes.zig: DIFFERENT"; exit 1; fi
rm -rf "$R/regen"
echo "== the engine, built with zig/build.sh and an empty cache ($R/zigcache)"
rm -f zig/bin/openswmm
ZIG_CACHE="$R/zigcache" zig/build.sh
rm -rf "$R/zigcache"
ls -l zig/bin/openswmm
if command -v zig >/dev/null 2>&1; then echo "zig $(zig version)"; else echo "zig $(python3 -m ziglang version)"; fi
echo "fused multiply-add instructions in the binary: $(objdump -d zig/bin/openswmm | grep -cE 'vfn?m(add|sub)' || true)"
