Free Pascal's internal ELF writer gives every routine its own section and cannot number more than 65,280 of them, so the 350,000-line engine unit linked only after switching to GNU as (`-Aas`).

Free Pascal 3.2.2 on Linux puts each routine in its own section (for smart linking) and writes the object file itself.
The engine unit (`pascal/gen/engine.pas`) has more sections than the ELF format numbers without its extended section
index, which the internal writer does not produce; the linker then reported

```
/usr/bin/ld.bfd: warning: /dev/shm/pas6_build/release/engine.o has a corrupt string table index
runswmm6.pas:(.text...): undefined reference to `ENGINE$_$T_F__GLOBAL_$__$$_SWMM_ENGINE_CREATE$$TOBJECT'
```

with every symbol of the unit missing. `pascal/build.sh` passes `-Aas`: Free Pascal writes assembly and GNU as
assembles it, numbering the sections correctly. The assembly is also what the x87 and fused-multiply-add census reads
(`-a` keeps it).
