`lseek(fd, 0, SEEK_END)` on a directory on ext4 returns 9,223,372,036,854,775,807, not an error: a runtime that sizes a buffer from it before reading asks for 2^63 bytes.

The Zig runtime opens an input stream by reading the whole file (`zig/rt/crt.zig`, `readWholeFile`): `open`, then the
size from `lseek` to the end, then an allocation of that size. A directory opened read-only succeeds (C++'s `ifstream`
opens one too, and the engine then fails to read it), so the code was written to notice the failed read and report an
empty, unreadable file:

```zig
const fd = open(@ptrCast(pb.ptr), O_RDONLY);
if (fd < 0) return null;
defer _ = close(fd);
const size = lseek(fd, 0, 2);
if (size < 0) return null;
var data = rt.gcSlice(u8, @intCast(size));
```

On this machine's ext4 the `lseek` of a directory returned 2^63 - 1, so the read was never reached: the collector
printed `Failed to expand heap by 9007199254741120 KiB` and the engine stopped with "out of memory" (exit 134) on the
two extra decks that give a directory where a file belongs, `dir_as_deck.inp` (the input file itself) and
`ppr_ueb_dir.inp` (`MET_FILE ../decks`), where the C++ engine reports the error and exits with 5. The fix asks
`fstat` first and treats a directory as an empty file that cannot be read, which is what the reference's report shows.
On tmpfs (`/dev/shm`, where the development copies ran) the same `lseek` fails with EINVAL, and the runtime would have
called the directory a file that cannot be opened, a different error; only the gate, which runs the decks in their
own ext4 folders, showed the crash. Check the file type with `fstat` before trusting a size from `lseek`.
