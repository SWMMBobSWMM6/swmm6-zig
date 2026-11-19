Killing `flock` does not cancel the command it started: once the lock is granted, the command holds the lock through the inherited file descriptor, and killing `flock` leaves it running, orphaned, while the chunk script that waited for `flock` goes on to its clean-up.

`zig/gate/run_chunk.sh` (after `perl/gate/run_chunk.sh`) runs the gate as

```bash
TMPDIR=/dev/shm flock -w ${WAIT:-900} "$LOCK" bash -c "...; nice -n 10 python3 gate.py '$NAME' ..." >> "$K/gate/${NAME}_run.txt" 2>&1
rc=$?
...
rm "results/$NAME"            # the symlink to the memory folder
...
cp -a "$M"/. "results/$NAME"/ 2>/dev/null
rm -rf "$M"                    # the memory folder the gate writes into
```

On 18 November the Zig port's checked-build chunk `zig6_s01` was queued behind its own extra-deck chunk, and was to be
cancelled because a translator bug had been found. `kill` was sent to its `flock` at 20:05:55, but `flock` had been
granted the lock at 20:05:49, the moment the extra chunk ended. `flock` died (rc=143 in `zig/gate/zig6_s01_times.txt`);
`gate.py` (parent now 1) kept the lock and kept running, and the script removed the symlink and the memory folder under
it. The model running at that moment, `HRSDtest_cim_7.inp`, lost the end of its report (RPTDIFF at line 177 of 1,225);
the next 294 models wrote their outputs to `gate/results/zig6_s01` on the disk, which had 0.9 GB free, until the
orphan was found in `ps` (`python3 gate.py zig6_s01 ...`, ppid 1) about ten minutes later and killed by its pid, with
its engine. Meanwhile the Free Pascal port's chunk waited for the lock the orphan held.

To cancel a queued chunk, first check whether its `started` line has been written to `NAME_times.txt` (then the run
has the lock): kill `gate.py` and its engine by pid, not `flock`. After any kill, look in `ps` for a `gate.py` or engine
whose parent is 1.
