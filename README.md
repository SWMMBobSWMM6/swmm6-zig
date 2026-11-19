# swmm6-zig: the OpenSWMM 6 1D engine in Zig, byte for byte

A translation of the 1D engine of OpenSWMM 6 (HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6)
into Zig, held to the same output as the C++ engine: the same binary `.out` file and the same `.rpt`
report, apart from the three clock lines. It is not SWMM6 and not a HydroCouple or EPA release; it is a
translation checked against SWMM6.

## Result

**480 of 480 models byte-identical** against the C++ reference engine built from the same commit and run on one thread
(`OMP_NUM_THREADS=1`), on the 480-model gate set (the one the SWMM5 ports were checked on), drawn from
[1729-SWMM5-Models-2030](https://github.com/SWMMBobSWMM6/1729-SWMM5-Models-2030). Gate run
`zig6_c01`; every result, with the SHA-256 of each `.out` and `.rpt`, is in `gate/evidence/`.

The same engine on the 452 extra decks: **452 of 452 extra decks byte-identical**. These are SWMM6's own tests, which the corpus cannot be:
the input files in the upstream repository's `tests` folder at 88329d6, and the synthetic decks of
[swmm6-rust](https://github.com/SWMMBobSWMM6/swmm6-rust)'s gate, which probe the finite-volume solver, its
structure coupling, the newer hydrology and the input checks. Gate runs
`zig6_x01`, `zig6_x02`, in `gate/evidence/` with the same hashes.

Checked twice more. An independent rerun of all 480 corpus models and all 452 extra decks from a clean copy of the repository (`git archive`), with
the translator rebuilt there, the engine (`zig/gen/engine.zig`, with the translator's two reports) and `zig/rt/primes.zig` regenerated there, all byte-identical to the committed files (`zig/results/zig6_v_build.txt`), and the engine built there with an empty cache; every status and every `.out` and `.rpt` hash equal to the first runs' (`zig/results/zig6_v_compare.txt`): gate runs
`zig6_v1`, `zig6_vx`, **932 of 932 byte-identical**. Then the main session's own check, from a
clean `git clone`: the translator rebuilt, the engine and `primes.zig` regenerated (identical again) and the engine built there with an empty cache of its own (`objdump -d` finds no fused multiply-add instruction); and gate runs `zig6_main` on 45 corpus models drawn at random (seed 20261110) plus the three decks that
SAVE and USE `cho.txt` (**48 of 48 byte-identical**) and `zig6_main_x` on 12 extra decks drawn the same way
(**12 of 12 byte-identical**). The math's own tests are in `zig/results/libm_tests.txt`.

The extra decks found two bugs that the corpus did not, both fixed before the published result: run `zig6_x01` passed 447 of 452, and `zig6_x02` passed the other five after the fixes. The translator, which drops code after a jump because Zig rejects unreachable code, took the statement `breakdown = ...;` for a `break` and left 46 lines of the finite-volume GMRES loop out (`lessons/62`); and the runtime sized a read buffer from `lseek`, which on ext4 is 2^63 - 1 for a directory (`lessons/63`).

**The checked build: 480 of 480 and 452 of 452, no trap.** The same sources built `-O ReleaseSafe` (bounds, null, integer overflow and cast checks on): runs `zig6_s02` and `zig6_s03`, in `zig/results/`. An earlier checked run, `zig6_s01`, was stopped part-way and is not a result (`zig/gate/zig6_s01_times.txt`).

A model passes when its `.out` is byte-identical to the reference's (when the reference writes one), its `.rpt` is
identical after removing the lines "Analysis begun", "Analysis ended" and "Total elapsed time", and its exit code is
the same (the command line exits nonzero when a model stops on an input error).

The translations, all from the same C# and gated the same way: swmm6-csharp, swmm6-go, swmm6-java, swmm6-typescript, swmm6-fortran, swmm6-python, swmm6-kotlin, swmm6-groovy, swmm6-javascript, swmm6-fsharp, swmm6-hy, swmm6-ruby, swmm6-php, swmm6-perl, swmm6-zig, under
[SWMMBobSWMM6](https://github.com/SWMMBobSWMM6).

## How it was made

The C++ engine was translated to C# first, and the C# gated to 480 of 480. The other languages are translated
from that C#, not from the C++. `tools/cs2x/Cs2Zig.cs` translates the verified C# engine (`cs/gen`) through Roslyn into one Zig file (`zig/gen/engine.zig`; the mapping is in `tools/cs2x/ZIG.md`). Zig has no classes, exceptions or closures and no garbage collector: C# classes become structs, inheritance an embedded base struct and a type id, virtual calls a switch on the type id, exceptions Zig error unions, lambdas functions with a context of pointers to the captured variables, and every allocation goes to the Boehm collector, zero-filled and never moved. `zig/rt` is the runtime library, written in Zig for this port. No math was translated: every libm call is an import from the system's glibc at the symbol versions the C++ engine links, built with `-mcpu=x86_64`, `-fno-builtin` and `-fno-compiler-rt` so that neither LLVM nor Zig's own math can stand in for it. Nothing in `zig/` loads anything from the other ports.

Nothing in the generated engine is edited by hand. Where the output depends on the C library (printf's rounding,
strtod, sscanf, the order of a hash table's nodes, introsort's swaps), the runtime reproduces glibc and libstdc++
exactly; the checks in `tests/` compare it with them case by case.

## Build and run

Needs Zig 0.15.2 (`pip install ziglang==0.15.2`, run as `python3 -m ziglang`; a `zig` on the PATH is used first), glibc on x86-64 and the Boehm collector `libgc.so.1` (Ubuntu package `libgc1`); the .NET 8 SDK only to regenerate the engine. Build: `zig/build.sh`. Then run a model the way the C++ command line runs it:

    zig/runswmm6 model.inp model.rpt model.out

To regenerate the engine: tools/cs2x/build_zig.sh, then dotnet tools/cs2x/bin/cs2zig.dll cs zig/gen, then zig/make_primes.sh. The C# engine it starts from is regenerated from the C++ source with
`tools/cpp2x` (see the header of `tools/cpp2x/emit_cs.py` and `cs/README.md`), which needs the OpenSWMM source at
commit 88329d6 and libclang.

## The gate

`gate/make_ref.sh` makes the reference outputs with the C++ engine (`ref/runswmm6`: build openswmm.engine at
88329d6 and run it single-threaded); `gate/gate.py NAME "zig/runswmm6" --resume` runs this engine on every model in
`gate/models_all.tsv` (paths relative to the corpus; set `SWMM_CORPUS`) and compares; `gate/cmp1.sh` checks one
model. The extra decks are listed in `gate/models_extra.tsv`, with paths relative to a folder that holds clones of
openswmm.engine (at 88329d6) and swmm6-rust: make their references with
`SWMM_CORPUS=FOLDER MODELS=gate/models_extra.tsv REF=$PWD/gate/ref_outputs_extra gate/make_ref.sh`, then run
`gate/gate.py NAME "zig/runswmm6" --models gate/models_extra.tsv --ref gate/ref_outputs_extra --root FOLDER --resume`.
The median time per model in the gate run was 0.12 s (the C# engine's: 0.76 s, which includes .NET's start-up and JIT compilation). The times were measured on a shared two-core cloud machine while other runs were going, so they are a
rough guide, not a benchmark.

## What this does not show

- Agreement on models outside the 480 and the 452. The two sets are broad (EPA's examples, the OWA EXTRAN set,
  hydrology, hydraulics, water quality, LID, RDII, controls, hot start, input errors, the FV solver and SWMM6's own
  tests), but a feature no gate model or deck uses is untested.
- The reference's parallel runs. Every parallel loop runs on one thread, in order, which is what the C++ engine
  does when it is held to one thread; results with OpenMP threads can differ in the last bits.
- The 2D and other modules of OpenSWMM 6 beyond the 1D engine the command line runs.

## License and attribution

This repository is a translation of the OpenSWMM 6 engine.

OpenSWMM Engine — Copyright 2026 HydroCouple Developers, licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE) and [NOTICE](NOTICE). Source: https://github.com/HydroCouple/openswmm.engine (branch
`swmm6_rel`, commit `88329d6`).

Every generated engine file here is a modified, mechanically translated form of the OpenSWMM sources: its header
names what it was generated from, and each C# file in `cs/gen` names the OpenSWMM source file it came from.

Portions derive from the USEPA Storm Water Management Model, which is in the public domain under 17 USC § 105. The
USEPA does not endorse this product, and neither does HydroCouple.

The translators, the runtime, the gate and the notes: Copyright 2026 Robert Dickinson, licensed under the Apache
License, Version 2.0.

## AI use

Made with Claude (Anthropic): the translators, the runtime, the gate and the notes are Claude's work, directed by
Robert Dickinson; the engine itself is OpenSWMM's, translated mechanically. See [AI-USE.md](AI-USE.md).
