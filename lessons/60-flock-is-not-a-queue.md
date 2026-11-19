`flock -w` is not a queue: when the shared gate lock is released, whichever waiter the kernel wakes first takes it, so a port that queues one chunk at a time loses to a port with several queued, and its waits run out.

Every gate run of every port waits for the same lock (`perl/gate/run_chunk.sh`, after `ruby/gate/run_chunk.sh`):

```bash
TMPDIR=/dev/shm flock -w ${WAIT:-900} "$LOCK" bash -c "...; nice -n 10 python3 gate.py ..."
```

and every background command of the session must end within two hours, so the wait and the run share that budget. On
14 November the PHP port queued its chunks several at a time; the Perl port's chunks `pl6_c08`, `pl6_c07`, `pl6_c06`,
`pl6_c04` and `pl6_c03`, each waiting 3,700 to 4,800 s, gave up without running (`ended ... rc=1` with no `started`
line in their `perl/gate/NAME_times.txt`) and were queued again, while the lock passed from one PHP chunk to the next.

What kept the slow models inside the budget was making each run short rather than each wait long: the chunks of two
slow models (up to 3,600 s) were cut into one-model chunks (`perl/gate/ids_s01.txt` to `ids_s26.txt`), so a chunk
could wait up to 3,700 s behind two others and still finish within two hours, and two were kept queued at a time.
When sharing a lock with other ports' queues, plan each run so that its longest wait plus its longest run fits the
time limit, record a wait that ran out in the times file, and queue the chunk again.
