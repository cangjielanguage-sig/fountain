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
├── f_base               BaseException (base class of ZipException)
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
  `addFileStream` (streaming path: 24-byte ZIP64 data descriptor), `openEntry` (**push mode**
  streaming entry: hands an `OutputStream` to the caller and compresses as data is produced),
  `addFile`, `addDirectory`.
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

// Push mode: the data is being produced right now (row-by-row XML / CSV / logs)
let sink = ByteBuffer()
let w2 = ZipWriter(sink)
let entry = w2.openEntry("sheet1.xml")
entry.write("<?xml version=\"1.0\"?><sheetData>".toArray())
entry.write("<row r=\"1\"/></sheetData>".toArray())
entry.close()          // writes the data descriptor and registers the central entry
w2.close()             // writes the central directory + EOCD; readable only after this
```

## API reference

### Top-level functions

```cangjie
public func zip(output: OutputStream, dir: Path,
    options!: ZipWriterOptions = ZipWriterOptions()): Int64
public func unzip(input: InputStream, dir: Path, limits!: ZipLimits = ZipLimits()): Int64
public func unzip(path: String, dir: Path, limits!: ZipLimits = ZipLimits()): Int64
```

| Function | Behavior |
| --- | --- |
| `zip` | Recursively packs a directory; each file uses `addFileStream` (streaming); directories are written as directory entries; returns the **file count** (directories excluded). Symbolic links are skipped, and directory links skip the whole subtree. |
| `unzip` | Extracts all entries; creates the target directory; overwrites existing files; returns the **file count** (directories excluded). Zip Slip, symlink, encrypted-ZIP and ZIP-bomb policies apply here. |

`unzip` is not transactional: on an encrypted entry or mid-way error, already extracted files remain
on disk (the current entry's partial file is removed). For all-or-nothing behavior, extract into a
temporary directory and replace the destination after success.

### `ZipReader`

```cangjie
public class ZipReader {
    public init(input: InputStream, limits!: ZipLimits = ZipLimits())
    public init(path: String, limits!: ZipLimits = ZipLimits())

    public func entries(): ArrayList<ZipEntry>
    public func contains(name: String): Bool
    public func read(name: String): ?Array<Byte>
    public func readAll(name: String): Array<Array<Byte>>
    public func open(name: String): ?InputStream
    public func openEntry(entry: ZipEntry): ?InputStream
    public func close(): Unit
}
```

- `ZipReader(input)` buffers the whole stream; `ZipReader(path)` uses `File.seek` windows without
  buffering the whole archive.
- After parsing, `entries` / `contains` / `read` / `open` are read-only and may be called
  concurrently; each `open` creates an independent cursor.
- `read` / `open` use the **last** same-name entry (later wins); `readAll` returns all same-name
  non-directory entries in central-directory order.
- `open` verifies CRC and uncompressed size only at EOF; a truncated stream or CRC mismatch throws
  `ZipException`.
- `read` / `open` do **no path safety checks**; path validation is only performed by `unzip`.
- `close()` is idempotent; after closing, `entries` / `read` / `open` throw `ZipException`.

### `ZipEntry`

```cangjie
public struct ZipEntry {
    public let name: String
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let crc32: UInt32
    public let method: UInt16
    public let isDirectory: Bool
    public let modifiedAt: Option<DateTime>
    public let localHeaderOffset: Int64
}
```

All values come from the **central directory**, not the local header. `isDirectory` is determined by
a trailing `/`; `modifiedAt = None` when the DOS time is all zero.

### `ZipWriter`

```cangjie
public class ZipWriter {
    public init(output: OutputStream, options!: ZipWriterOptions = ZipWriterOptions())
    public prop position: Int64
    public prop spilling: Bool

    public func add(name: String, data: Array<Byte>): String
    public func addFileStream(name: String, input: InputStream): String
    public func openEntry(name: String): ZipEntryOutputStream
    public func addFile(name: String, path: Path): String
    public func addDirectory(name: String): String
    public func close(): Unit
}
```

| Method | Path | Notes |
| --- | --- | --- |
| `add` | Memory | Data is already in memory; writes real local headers without a data descriptor. Above `memoryEntryThreshold` it spills to a temp file and switches to the streaming path. |
| `addFileStream` | Streaming | Unknown length; writes bit 3 + a 24-byte ZIP64 data descriptor. |
| `openEntry` | Push | Returns a `ZipEntryOutputStream`; the caller writes data, and closing the entry writes the descriptor and registers the central directory. |
| `addFile` | Streaming | Reads a disk file; **follows symbolic links** (the caller explicitly names one file). |
| `addDirectory` | — | Writes a directory entry (appends `/`); same-name directories merge. |

- Every `add*` returns the **actual written name**; name collisions are renamed (`a.txt` → `a_2.txt`).
- `close()` writes the central directory + EOCD; it is required and idempotent. The archive is only
  readable after closing.
- `ZipWriter` is not thread-safe; `spilling` is atomic, but `position` and `spilling` are not
  guaranteed to be consistent with each other.
- After a write error the writer becomes dirty and any further `add*` / `close()` throws
  `ZipException`.

### `ZipEntryOutputStream`

```cangjie
public class ZipEntryOutputStream <: OutputStream {
    public prop entryName: String
    public prop count: Int64
    public func write(buffer: Array<Byte>): Unit
    public func flush(): Unit
    public func close(): Unit
}
```

- `count` is the number of **uncompressed** bytes written.
- `close()` finishes the entry and registers it in the central directory; it is idempotent and no
  further writes are allowed.
- A write failure marks the owning `ZipWriter` dirty.

### `ZipWriterOptions`

```cangjie
public class ZipWriterOptions {
    public var memoryEntryThreshold: Int64
    public var tempDir: ?Path
    public var method: CompressionMethod

    public init(memoryEntryThreshold!: Int64 = /* platform default */, tempDir!: ?Path = None,
        method!: CompressionMethod = CompressionMethod.Deflate)
    public static func forServer(): ZipWriterOptions
    public static func forLowMemory(): ZipWriterOptions
}
```

| Field / preset | Default | Description |
| --- | --- | --- |
| `memoryEntryThreshold` | Linux/gnu 64 MB, others 16 MB | `add()` spills to a temp file above this |
| `tempDir` | `None` | Preferred temp directory; falls back through option → `TMPDIR` → system temp → `./.fountain_tmp/` |
| `method` | `Deflate` | Use `Stored` for already-compressed data (JPEG/MP4/ZIP) |
| `forServer()` | 64 MB | Server preset |
| `forLowMemory()` | 8 MB | Low-memory preset |

If all four temp directory choices are unwritable, it throws instead of falling back to memory.

### `ZipLimits`

```cangjie
public struct ZipLimits {
    public let maxEntrySize: Int64        // 512 MB
    public let maxTotalSize: Int64        // 2 GB, per reader instance
    public let maxEntries: Int64          // 65535
    public let ratioWarnThreshold: Int64  // 1000, warning only
}
```

- `maxTotalSize` is the cumulative limit **per `ZipReader` instance**, not a process-wide quota.
- Counting uses actual decompressed bytes, not the header's `uncompressedSize`.
- `maxEntrySize` has two layers: reject before opening when the central-directory value already
  exceeds it; abort during streaming based on actual bytes when the header lies.
- `maxEntries` is enforced while parsing the central directory. Writers have no entry-count limit;
  entry counts ≥ `0xFFFF` upgrade to ZIP64 automatically.

### `CompressionMethod` / `ZipException`

```cangjie
public enum CompressionMethod {
    | Stored
    | Deflate
    public prop value: UInt16
    public static func fromValue(value: UInt16): ?CompressionMethod
}

public class ZipException <: BaseException {
    public init(message: String)
}
```

`f_zip` throws only `ZipException`: invalid archives, CRC mismatches, encrypted entries, invalid
paths and limit violations all use it.

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
