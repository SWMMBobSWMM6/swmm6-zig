A cleanup of this port's scratch files in /dev/shm used the glob `/dev/shm/swmmsave.*`, which also matched the SAVE-file backup of the Perl port's gate run that was going on at that moment, so that run could not restore `Hydrology/cho.txt` after `save_rtk_long.inp`; the file came out intact only because the Perl engine had written the same bytes.

Every port's gate wrapper (`runswmm6_saves.sh`) backs up the files a deck SAVEs to `$(mktemp -d "$TMPDIR/swmmsave.XXXXXX")`,
and every gate run sets `TMPDIR=/dev/shm`. After the PHP gate had finished, the scratch clean-up was:

```bash
rm -rf /dev/shm/php6dev /dev/shm/php6dbg /dev/shm/php6_eng /dev/shm/php6_v /dev/shm/php6_mon_* /dev/shm/swmmsave.* 2>/dev/null
```

At 22:45 the Perl port's chunk `pl6_c04` was running `Hydrology/save_rtk_long.inp`, which SAVEs RDII to `cho.txt`, the
file `one_sub_one_rdii_node.inp` and `Use_SeasonalRDIIn.inp` USE. Its wrapper had copied the original `cho.txt` into
its `swmmsave.*` folder at 22:33; the glob deleted that folder (with `2>/dev/null` hiding nothing, because nothing
failed). When the Perl engine finished at 22:47 the wrapper's restore loop found no list of files and restored nothing,
leaving the `cho.txt` the Perl engine had just written. That file is 1,114,474 bytes with md5
5b0ca1fe78588202fa779dbfa417b089, the original's, because the SAVE rewrites the file the corpus ships (the PHP engine,
run on a copy of the folder, writes the same bytes); with an engine that wrote anything else, the corpus would have
been changed for every later run of every port, and `cho.txt` is not under version control.

Delete only paths this port created, by exact name, never by a pattern in a folder other ports use; a wrapper's
temporary folders belong to whoever is running it, and the gate wrappers' `swmmsave.*` folders remove themselves.
