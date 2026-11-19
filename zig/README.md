# The OpenSWMM 6 1D engine in Zig, byte for byte

A translation of the 1D engine of OpenSWMM 6 (HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6) into
Zig, held to the same output as the C++ engine: the same binary `.out` file and the same `.rpt` report, apart from
the three clock lines. It is a translation checked against SWMM6, not SWMM6 and not a HydroCouple or EPA release.

## Result

**480 of 480 models byte-identical** against the C++ reference engine built from the same commit and run on one
thread, on the 480-model gate set the SWMM5 ports were checked on, drawn from 1729-SWMM5-Models-2030: run `zig6_c01`
(commit cef0570), 733 s of engine time in all, a median of 0.12 s per model, the slowest `EPA/72_H&H_Elements(2).inp`
(136 s) and `Hydrology/SCANLON.inp` (121 s). The C# port, for comparison, took 1,002 s with a median of 0.76 s
(`gate/evidence/cs8.json`); most of its median is .NET's start.

**452 of 452 extra decks byte-identical**: SWMM6's own tests (the input files in the upstream repository's `tests`
folder at 88329d6) and the synthetic decks of swmm6-rust's gate. Run `zig6_x01` (cef0570) passed 447; the other five
failed on two bugs, both fixed (below), and passed in run `zig6_x02` (commit 6668465, 5 of 5). 830 s of engine time
for the 452, a median of 0.07 s per deck, the slowest `refactored_small.inp` (352 s) and `legacy_small.inp` (348 s).

The two bugs the extra decks found:

- `sdm_fv_o1.inp`, `sdm_fv_o2.inp` and `sdm_fv_o2_superbee.inp` stopped at step 193 with "FV conservative scalar
  transfer did not converge". The translator, which drops code after a jump because Zig rejects it, took the
  statement `breakdown = ...;` for a `break`, and the rest of the GMRES Arnoldi loop (46 lines) was left out
  (`../lessons/62`). The fix changed that one loop of the generated engine and nothing else.
- `dir_as_deck.inp` and `ppr_ueb_dir.inp`, which give a directory where a file belongs, stopped with "out of memory":
  the runtime sized its read buffer from `lseek`, which on ext4 is 2^63 - 1 for a directory (`../lessons/63`).

**The checked build: 480 of 480 and 452 of 452, no trap.** The same sources built `-O ReleaseSafe` (`BUILD_MODE=ReleaseSafe
BIN_SUFFIX=_safe zig/build.sh`), which keeps Zig's run-time checks: array and slice bounds, null optionals, integer
casts that do not fit, overflow of the arithmetic Zig checks (the engine's own `+ - *` are the wrapping operators, as
C# is unchecked). Runs `zig6_s02` (corpus, 480 of 480, 802 s) and `zig6_s03` (extra, 452 of 452, 733 s), commit
6668465. No check fired, so there was no trap to fix or to trace to upstream behaviour.

**The independent rerun: 480 of 480 and 452 of 452.** A clean copy of commit 6668465 (`git archive`) in memory,
where the translator was rebuilt, the engine regenerated from `cs/gen` (`engine.zig` and the translator's two reports
byte-identical to the committed ones), the one generated runtime file written again (`rt/primes.zig`,
byte-identical), and the engine built with `zig/build.sh` and an empty Zig cache, with no fused multiply-add in it
(`results/zig6_v_build.txt`). The first gates took well under five hours of engine time, so the copy was gated on
everything: runs `zig6_v1` (corpus, 480 of 480, 782 s) and `zig6_vx` (extra, 452 of 452, 893 s). Every status and
every `.out` and `.rpt` hash equals the first runs' (`gate/compare_rerun.py`, `results/zig6_v_compare.txt`). The
commits after 6668465 change only notes and results.

**The main session's check: 48 of 48 and 12 of 12.** A clean `git clone` of commit 999d22a (in memory), where the
translator was rebuilt and the engine and `rt/primes.zig` regenerated (no file changed: `git status` empty), and the
engine built with `zig/build.sh` and an empty Zig cache of its own (`objdump -d` finds no fused multiply-add
instruction), then gated: run `zig6_main` on 45 corpus models drawn at random (`random.Random(20261110)`) plus
`Hydrology/save_rtk_long.inp`, `one_sub_one_rdii_node.inp` and `Use_SeasonalRDIIn.inp`, the decks that SAVE and USE
`cho.txt` (48 of 48; 26 s), and run `zig6_main_x` on 12 extra decks drawn the same way (12 of 12; 0.7 s); the same
samples as the other ports' checks. Ids in `gate/ids_main_check.txt` and `gate/ids_main_check_extra.txt`;
`Hydrology/cho.txt` was unchanged afterwards (1,114,474 bytes, md5 5b0ca1fe78588202fa779dbfa417b089).

Every result, with the SHA-256 of each `.out` and `.rpt`, is in `results/NAME.json`, with the run's log beside it
(`results/NAME_run.txt`); the start and end of each run, and the engine it ran, are in `gate/NAME_times.txt`.
`gate/summarize.py` puts them in one table. A model passes when its `.out` is byte-identical to the reference's (when
the reference writes one), its `.rpt` is identical after removing the lines "Analysis begun", "Analysis ended" and
"Total elapsed time", and its exit code is the same. The gate runs every model through `runswmm6_saves.sh`, which backs
up the files a deck SAVEs and restores them afterwards, so that no deck changes a file another deck reads. Each run
used a fixed copy of the engine as committed (`gate/snapshot.sh`).

Run `zig6_s01` is not a result. It was the first checked-build run, on cef0570, queued and then cancelled when the
GMRES bug was found; the cancel was sent to its `flock` six seconds after the lock had been granted, so `gate.py` went on
without the chunk script, for 311 models, until it was found and killed (`gate/zig6_s01_times.txt`,
`results/zig6_s01_orphaned.jsonl`, `../lessons/65`). After all the runs `Hydrology/cho.txt` is 1,114,474 bytes, md5
5b0ca1fe78588202fa779dbfa417b089.

## How it was made

The C++ engine was translated to C# first (`cs/gen`, 480 of 480), and this engine is translated from that C#, not
from the C++, by a translator written for it: `tools/cs2x/Cs2Zig.cs`, `ZigTypes.cs`, `ZigFn.cs` and `ZigExpr.cs`
(2,523 lines), which read the C# (`cs/gen`, and the engine's hand-written partial classes `cs/runtime/Hand_*.cs`)
through Roslyn's semantic model and print one Zig file, `gen/engine.zig` (240,507 lines). C# classes become structs
held by optional pointers, inheritance an embedded base struct and a type id, virtual calls a switch on the type id,
exceptions Zig error unions (every engine function returns `E!T`) with the thrown object held by the runtime, and
lambdas functions with a context of pointers to the captured variables. The mapping is in `tools/cs2x/ZIG.md`; every
runtime name the engine uses is in `cs2zig_runtime.txt` (475), and the constructs left untranslated in
`cs2zig_todo.txt` (none).

The runtime (`rt/`, 7,155 lines of Zig, 42 of them the prime list written by `make_primes.sh`) is the part of the
C++ standard library and of the C library that the engine calls: vectors, maps and sets with libstdc++'s hash-table
node order and growth (`std::hash` is `_Hash_bytes`), strings, iterators, pointers, introsort, merge sort and heap
sort step for step, glibc-exact printf (exact decimal expansion), strtod with exact rounding and glibc's ERANGE,
glibc's sscanf, stdio files, iostreams and the file system as the C# port has them. It is written in Zig for this port;
the printf, strtod and stdio code was carried over from the SWMM5 Zig port (`swmm5-ports/zig/src/rt.zig`) and
extended. `main.zig` is the command line (`src/cli/main.cpp`, by way of the C# port's `Program.cs`). Nothing calls
another port's engine or runtime.

The math is glibc's own: the engine's 19 functions (exp, log, pow, sin, cos, tan, asin, acos, atan, log10; atan2,
log2, sinh, tanh, expm1, log1p, cosh, cbrt, hypot) and fmod, remainder, round, nextafter, floor, ceil and trunc are
`extern` calls into the system's libm. The build passes `-fno-builtin`, so LLVM keeps every call as written, and
`-fno-compiler-rt`, so no copy of a math function in Zig's compiler-rt captures one; the binary imports them at the
same symbol versions as the C++ engine's `libopenswmm.engine.so.6` (`exp`, `log`, `pow`, `log2` at GLIBC_2.29, `hypot`
at GLIBC_2.35, `fmod` at GLIBC_2.38, the rest at GLIBC_2.2.5; `objdump -T`). `sqrt` and `fabs` are Zig's builtins
(`sqrtsd` and a mask) and `copysign` a bit copy, which IEEE fixes. `-mcpu=x86_64` keeps the baseline instruction set,
so no fused multiply-add can appear: `objdump -d bin/openswmm` finds no `vfmadd`, `vfmsub` or `vfnmadd`. The local time
for `ctime` (the report's clock lines) is glibc's `localtime_r`.

Memory: every object, array and string is allocated by the Boehm collector (the system's `libgc.so.1`, 8.2.6),
zero-filled, which is C#'s default value for every field; nothing is freed by hand, and the collector reclaims only
what nothing points to any more. It never moves an object. No number the engine computes depends on an address, with
one exception the gate covers: a hash table keyed by an object pointer hashes the address, as libstdc++ does, so its
iteration order can differ from run to run and from the C++ engine's (it does in the C# port too, which hashes object
identity); every gate run passed, so no output depends on that order. The heap starts at 64 MB; the largest models
measured, `HRSDtest_cim_7.inp` (a 230 MB `.out`), `attenuation_KW_High_CE.inp` and `292_Storage_Nodes_200_Subs.inp`,
peaked at 76 MB resident, and `force_legacy.inp` at 165 MB.

Nothing in the generated engine is edited by hand: every fix went into the translator or the runtime.

## How it was checked

- **The math**: `test/run_libm_tests.sh` compares the functions as the engine calls them (through `rt.Math` and
  `rt.LibM`) with the system's glibc 2.39, bit for bit, by the method of `tools/libm/test`: a million arguments per
  function over the ranges SWMM uses with special values, and 200,000 to 700,000 edge cases each, for exp, log, log10,
  pow, sin, cos, tan, asin, acos and atan; a million per function over wide ranges and every branch threshold, with
  signed zeros, infinities, subnormals and NaNs of both signs with several payloads, for cbrt, hypot, atan2, cosh,
  sinh, tanh, log2, expm1 and log1p; a million each for sqrt, floor, ceil, trunc, fabs, round and copysign. 29,364,615
  results, **0 differences**, NaN signs and payloads included (`results/libm_tests.txt`).
- **The C library**: `test/run_crtcheck.sh` runs the cases of `tests/crtcheck` (C programs using the system's own
  glibc) through the runtime (`test/crtcheck.zig`, after `php/test/crtcheck.php`): libm through the runtime, 0
  differences in 300,576 cases for each of 27 functions; printf, 0 differences in 179,756 cases and in 101,800 more
  covering every conversion the engine's format strings use; sscanf, 0 in 1,728; from_chars, strtol, strtod, atoi,
  ctime, ctype and get_nprocs, 0 in 752; and 56 unit checks of the rest (sscanf targets, strtod's ERANGE, binary and
  text files, printf argument kinds, math corners, C strings), 0 failures (`results/crtcheck.txt`). The first run found
  differences on printf conversions the engine does not use, all fixed: the `#` flag on `%o`, `%x` and `%X`, the `h`
  and `hh` modifiers, a null `%s` with a precision, zero padding and rounding of `%a`, and glibc's `%#g` on a carry
  (`1.e+06` for 999999.5; `../lessons/64`); and `ctime` in UTC instead of the local time zone.
- **libstdc++**: `test/run_std_checks.sh` runs the cases of `tests/stdcheck`: the permutations std::sort,
  std::stable_sort and std::partial_sort leave on keys with many ties (6,447 cases, over structs, object pointers,
  ints and doubles) and the hash tables' iteration order, bucket counts and std::hash (167 lines), identical to
  libstdc++ (`results/std_checks.txt`). The struct case found that Zig may pass a struct argument by reference, so the
  heap sort lost elements (`../lessons/61`); the engine sorts only pointers and numbers, and the runtime now copies such
  arguments first.
- **The engine**: the gate (above), run on the corpus and on the extra decks, the checked build and the independent
  rerun.

## Build and run

Needs Zig 0.15.2 (`pip install ziglang==0.15.2` gives `python3 -m ziglang`, which `build.sh` uses when no `zig` is on
the path), glibc on x86-64 and the Boehm collector (`libgc.so.1`, Ubuntu's `libgc1`). Build (about three minutes,
1.2 GB of memory; the Zig cache goes to `/dev/shm/zig6_cache`, or `ZIG_CACHE`):

    zig/build.sh                                          # bin/openswmm, ReleaseFast
    BUILD_MODE=ReleaseSafe BIN_SUFFIX=_safe zig/build.sh  # bin/openswmm_safe, the checked build

Run a model the way the C++ command line runs it:

    zig/runswmm6 model.inp model.rpt model.out

The translator needs the .NET 8 SDK (8.0.132 was used). To regenerate the engine from `cs/gen`:
`tools/cs2x/build_zig.sh && dotnet tools/cs2x/bin/cs2zig.dll cs zig/gen` (about a minute); `zig/make_primes.sh`
writes `rt/primes.zig` again.

The gate: `zig/gate/run_chunk.sh NAME corpus|extra [IDS_FILE|-] [ENGINE]` runs `gate/gate.py` on this port with the
SAVE-file wrapper, inside the shared lock (`WAIT` seconds at most); `gate/snapshot.sh` makes the fixed copy a chunk
runs (`BIN_SUFFIX=_safe` for the checked build); `gate/rerun_build.sh` makes the clean copy of a commit that the
independent rerun gates; `gate/compare_rerun.py` compares the rerun with the first runs; `gate/summarize.py` lists the
runs.

## What this does not show

- Agreement on models outside the 480 and the 452. A feature no gate model or deck uses is untested.
- The reference's parallel runs: every parallel loop runs on one thread, in order, as the C++ engine does when it
  is held to one thread.
- The 2D and other modules of OpenSWMM 6 beyond the 1D engine the command line runs.
- Every input to the math functions: they are glibc's own, and the tests check that each call reaches glibc with the
  right argument; another glibc would give that glibc's results.
- iostreams and the file system on their own: the stream check of `tests/stdcheck/run_stream.sh` was not ported (as in
  the PHP port); these parts of the runtime are exercised through the engine and the checks above.
- Another Zig: the engine was built and checked with Zig 0.15.2 only. Zig may pass struct arguments by reference
  (`../lessons/61`); the generated code copies every parameter at entry, but a newer compiler's rules were not tested.
- No person has reviewed the generated code line by line; the evidence is the gate, the checked build and the runtime
  checks.
- Speed. The times above were measured on a shared two-core machine while another port's work was going.

## License and attribution

The engine is a translation of the OpenSWMM Engine, Copyright 2026 HydroCouple Developers, licensed under the
Apache License, Version 2.0 (https://github.com/HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6).
Portions derive from the USEPA Storm Water Management Model, which is in the public domain; the USEPA does not
endorse this translation, and neither does HydroCouple. The port contains no glibc code: the math is the system's
glibc, called at run time and not copied (glibc is under the GNU Lesser General Public License 2.1 or later). The
Boehm collector is linked at run time (its own permissive license); Zig's standard library (MIT) is compiled in.

## AI use

The translator (`tools/cs2x/Cs2Zig.cs`, `ZigTypes.cs`, `ZigFn.cs`, `ZigExpr.cs`), the runtime (`zig/rt`), the
command line (`zig/main.zig`), the port's scripts and checks and these notes were written by Claude, Anthropic's AI
model, for Robert Dickinson, who directed the work. The engine is a mechanical translation of OpenSWMM 6 (Apache-2.0,
HydroCouple Developers), itself derived in part from the public-domain EPA SWMM; it was checked by running it against
the C++ engine, not by reading it. See `../AI-USE.md`.
