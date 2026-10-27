# f_zip

ZIP container reader/writer for Cangjie. The **container layer** (local headers, central directory,
EOCD, ZIP64, CRC bookkeeping) is implemented in this module; only the deflate *data stream* is
delegated to `stdx.compress.zlib` (`WrapType.DeflateFormat`). No third-party ZIP library, no FFI,
no native linking.

## STDX dependency

```sh
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
```

## Dependencies

```
f_zip
├── stdx.compress.zlib   DecompressInputStream / CompressOutputStream
├── f_util               crc32(data: Array<Byte>): UInt32
├── f_io                 ByteBuffer (random access for the in-memory mode)
├── f_log                LoggerFactory (spill debug log, ratio warning, skipped symlinks)
├── charset4cj           GBK decoding (file name fallback chain)
└── std.fs / std.io / std.time / std.sync
```

## Features

- **Reading**: `ZipReader(input)` buffers the whole stream; `ZipReader(path)` uses `File.seek`
  window reads, so RSS does not grow linearly with a 1 GB archive. Entry listing, `read`
  (last match wins), `readAll`, and `open` for streaming decompression with an independent
  cursor per call (concurrent opens are safe).
- **Writing**: `add` (in-memory path: real values in the local header, no descriptor),
  `addFileStream` (streaming path: 24-byte ZIP64 data descriptor), `addFile`, `addDirectory`.
- **ZIP64 in both directions**: reads EOCD64 / locator / extra `0x0001`; writes it only when a
  field actually overflows, so small archives contain no ZIP64 bytes at all.
- **Secure by default**: Zip Slip rejection, symlink skipping, ZIP bomb limits, encrypted ZIP rejection.
- **Large entries stay out of memory**: `add()` spills over-threshold entries to a temp file and
  switches to the streaming path; `zip` / `unzip` are streaming end to end.

## Quick start

```cangjie
import fountain::f_zip.*

// Pack a directory (each file goes through the streaming path)
let out = File("export.zip", OpenMode.Write)
let count = zip(out, Path("/data/reports"))
out.close()
println("${count} files")

// Unpack (defaults: 512 MB per entry / 2 GB cumulative / 65535 entries)
let files = unzip("/data/export.zip", Path("/tmp/unpacked"))
println("${files} files")

// Read a single entry
let reader = ZipReader("/data/export.zip")
if (let Some(bytes) <- reader.read("a.txt")) {
    println(String.fromUtf8(bytes))
}
reader.close()

// Streaming write (safe even when the length is unknown)
let buffer = ByteBuffer()
let writer = ZipWriter(buffer)
writer.add("config.json", "{ }".toArray())
writer.addFileStream("huge.log", File("/var/log/app.log", OpenMode.Read))
writer.close()
```

## Security defaults

| Risk | Default behavior |
| --- | --- |
| Zip Slip | absolute paths, `..` segments, or anything escaping the target dir → rejected before any write |
| Symlinks | `unzip` / `zip` skip them with a warning; `addFile` follows (caller named a single file) |
| ZIP bombs | four `ZipLimits` caps counted by **actual decompressed bytes**; partial files are removed |
| Encrypted ZIP | bit 0 / bit 6 set → error, no partial support |

## Documentation

- `doc/f_zip模块设计.md` — design document (21 decisions, byte layouts, implementation order)
- `doc/api.md` — the nine public names and their constraints (per-instance limits, non-thread-safe
  writer, `spilling` semantics)
- `doc/兼容性例外.md` — registry of real-world samples that deviate from APPNOTE (initially empty)
