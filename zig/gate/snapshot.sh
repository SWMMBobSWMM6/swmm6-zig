#!/bin/bash
# snapshot.sh - the engine a gate chunk runs: copy zig/bin/openswmm and the launchers to /dev/shm/zig6_eng/<commit>/zig
# and print the SAVE-file wrapper's path there (BIN_SUFFIX=_safe: the checked build, bin/openswmm_safe, to
# /dev/shm/zig6_eng/<commit>_safe/zig). The binary must be built from the committed sources (the script
# refuses when zig/rt, zig/gen, zig/main.zig or zig/build.sh differ from HEAD, or the binary is older than them), so
# a chunk runs a fixed commit, and rebuilding the tree while a chunk is queued or running cannot change what it runs
# (lessons/12: never rewrite a file a running program maps).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.
set -e
Z=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$Z/.." && pwd)
git -C "$ROOT" diff --quiet HEAD -- zig/rt zig/gen zig/main.zig zig/build.sh || { echo "snapshot.sh: uncommitted engine changes" >&2; exit 1; }
for f in "$Z"/rt/*.zig "$Z"/gen/engine.zig "$Z"/main.zig; do [ "$Z/bin/openswmm${BIN_SUFFIX:-}" -nt "$f" ] || { echo "snapshot.sh: bin/openswmm${BIN_SUFFIX:-} is older than $f" >&2; exit 1; }; done
C=$(git -C "$ROOT" rev-parse --short=7 HEAD)
D=/dev/shm/zig6_eng/$C${BIN_SUFFIX:-}/zig
if [ ! -x "$D/bin/openswmm" ]; then
  mkdir -p "$D/bin"
  cp "$Z/bin/openswmm${BIN_SUFFIX:-}" "$D/bin/openswmm"
  cp "$Z/runswmm6" "$Z/runswmm6_saves.sh" "$D/"
fi
echo "$D/runswmm6_saves.sh"
