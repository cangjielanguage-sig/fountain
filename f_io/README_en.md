# f_io

The Cangjie I/O utility library, providing memory mapping, streaming I/O and similar features.

## Documentation

### pipe / asyncPipe / copyToCType

## pipe

```cj
public func pipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

Transfers all the data of `input` to `output` through a buffer.

## asyncPipe

```cj
public func asyncPipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

Executes `pipe` in a new thread.

## copyToCType

```cj
public func copyToCType<T>(input: InputStream): T where T <: CType
```

Reads `sizeOf<T>()` bytes from the `InputStream` and interprets them as a CType value. Throws `IllegalSizeException` when there are not enough bytes.


Top-level utility functions: data pipe, asynchronous pipe, InputStream to CType.

### BytePointerStream


```cj
public class BytePointerStream <: IOStream & Resource
```

A byte stream based on a native memory pointer, supporting reading and writing `CPointer<Byte>` and `Array<Byte>`.

## Constructors

| Signature | Description |
|------|------|
| `init(pointer: CPointer<Byte>, size: Int64, readable!: Bool = true, writable!: Bool = true)` | Based on an existing pointer |
| `init(size: Int64, readable!: Bool = true, writable!: Bool = true)` | Allocate new memory (LibC.malloc) |

## Properties

| Name | Type | Description |
|------|------|------|
| `readable` | `Bool` | Whether it is readable |
| `writable` | `Bool` | Whether it is writable |
| `readOffset` | `Int64` | Read offset |
| `writeOffset` | `Int64` | Write offset |
| `length` | `Int64` | Total mapping size |

## Methods

| Method | Signature | Description |
|------|------|------|
| read | `func read(p: CPointer<Byte>, maxSize: Int64): Int64` | Read into a CPointer |
| read | `func read(buffer: Array<Byte>): Int64` | Read into an Array |
| write | `func write(p: CPointer<Byte>, size: Int64): Unit` | Write from a CPointer; throws when there is not enough space |
| write | `func write(buffer: Array<Byte>): Unit` | Write from an Array; throws when there is not enough space |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | Release the memory (if freeable) |


A byte stream based on a native memory pointer, supporting reading and writing `CPointer<Byte>` and `Array<Byte>`.

### DummyInputStream


```cj
public class DummyInputStream <: InputStream & Resource
```

An empty input stream, used for testing or as a placeholder.

## Static constants

| Name | Description |
|------|------|
| `THROW_ON_ACCESSING` | Throws on read |
| `SILENCE` | Returns 0 on read |

## Methods

| Method | Signature | Description |
|------|------|------|
| read | `func read(buffer: Array<Byte>): Int64` | Depends on the throwing flag |
| isClosed | `func isClosed(): Bool` | Always returns false |
| close | `func close(): Unit` | No-op |


An empty input stream, used for testing or as a placeholder.

### DummyOutputStream


```cj
public class DummyOutputStream <: OutputStream & Resource
```

An empty output stream, used for testing or as a placeholder.

## Static constants

| Name | Description |
|------|------|
| `THROW_ON_ACCESSING` | Throws on write/flush |
| `SILENCE` | Silently ignored |

## Methods

| Method | Signature | Description |
|------|------|------|
| write | `func write(buffer: Array<Byte>): Unit` | Depends on the throwing flag |
| flush | `func flush(): Unit` | Depends on the throwing flag |
| isClosed | `func isClosed(): Bool` | Always returns false |
| close | `func close(): Unit` | No-op |


An empty output stream, used for testing or as a placeholder.

### ExtendByteBuffer


```cj
public interface ExtendByteBuffer
```

A typed read/write interface for ByteBuffer, supporting big-endian/little-endian byte order.

## Methods

| Category | Method | Return type |
|------|------|---------|
| Read | `readBool/readUInt8/readUInt16/readUInt32/readUInt64/readInt8/readInt16/readInt32/readInt64/readFloat16/readFloat32/readFloat64` | `?T` |
| Write | `writeBool/writeUInt8/writeUInt16/writeUInt32/writeUInt64/writeInt8/writeInt16/writeInt32/writeInt64/writeFloat16/writeFloat32/writeFloat64` | `Unit` |

All methods take an `endian!: Endian` argument (`Endian.Platform` by default).

## Extension

```cj
extend ByteBuffer <: ExtendByteBuffer
```

`std.io.ByteBuffer` implements `ExtendByteBuffer`.

A typed read/write interface for ByteBuffer, supporting big-endian/little-endian byte order.

### MMapFile


> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public class MMapFile <: Resource & IOStream
```

A memory-mapped file. The write mapping is relocated to the size of mapLength on every write, while the read mapping is decided dynamically by mapLength and the remaining length. The file is opened write-only and is extended automatically when it is too short.

## Constructors

| Signature | Description |
|------|------|
| `init(file: File, prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, offset!: Int64 = 0, mapLength!: Int64 = DEFAULT_MMAP_BYTES)` | Map based on a file |
| `static func anonymous(prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, mapLength!: Int64 = DEFAULT_MMAP_BYTES): MMapFile` | Anonymous mapping |

## Properties

| Name | Type | Description |
|------|------|------|
| `info` | `FileInfo` | File information |
| `isReadable` | `Bool` | Whether it is readable |
| `isWritable` | `Bool` | Whether it is writable |
| `isSyncable` | `Bool` | Whether it is syncable (not Private and not Anonymous) |
| `isAnonymous` | `Bool` | Whether it is an anonymous mapping |
| `readOffset` | `Int64` | Read offset |
| `writeOffset` | `Int64` | Write offset |
| `length` | `Int64` | Size of the mapped memory |

## Methods

| Method | Signature | Description |
|------|------|------|
| syncAndUnmap | `func syncAndUnmap(): Unit` | Synchronize and unmap |
| sync | `func sync(flag: MSyncFlag): Unit` | Synchronize according to the flag |
| remap | `func remap(offset: Int64, mapLength!: Int64, flag!: MMapFlag): MMapFile` | Remap |
| setLength | `func setLength(length!: Int64): Unit` | Set the file length |
| read | `func read(p: CPointer<Byte>, maxSize: Int64): Int64` | |
| read | `func read(buffer: Array<Byte>): Int64` | |
| write | `func write(p: CPointer<Byte>, s: Int64): Unit` | |
| write | `func write(buffer: Array<Byte>): Unit` | |
| flush | `func flush(): Unit` | Equivalent to sync(MSyncFlag.Sync) |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | sync + unmap + close file |

## Related types

- ToMMap — interface; File extends this interface
- MMapProt — protection flag enum
- MMapFlag — mapping flag enum
- MSyncFlag — synchronization flag enum


A memory-mapped file supporting read/write mapping, synchronization and remapping.

### ToMMap


> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public interface ToMMap
```

## Methods

| Method | Signature |
|------|------|
| mmap | `func mmap(offset: Int64, mapLength: Int64, flag!: MMapFlag): MMapFile` |

## Extension

```cj
@When[os == "Linux"]
extend File <: ToMMap
```

`std.fs.File` extends `ToMMap`, and prots are determined from `canRead()`/`canWrite()`.


An interface; std.fs.File extends this interface to create an MMapFile.

### NonblockingQueueStream / BlockingQueueStream

The base class of both, `QueueInputStream`, is a `sealed abstract class` (a package-level type, **not public API**); it provides `init(size: Int64, closeOnEnd!: Bool = true)` and two `add` methods: `add(stream: InputStream)` and `add(bytes: Array<Byte>)`.

## NonblockingQueueStream

```cj
public class NonblockingQueueStream <: QueueInputStream
```

A queue-style input stream supporting the sequential reading of several added InputStreams; reading is non-blocking and returns 0 when there is no data.

## BlockingQueueStream

```cj
public class BlockingQueueStream <: QueueInputStream
```

A queue-style input stream supporting the sequential reading of several added InputStreams; reading blocks, waiting for data to become available.

### RotatableBuffer

```cj
public class RotatableBuffer
```

A rotatable buffer supporting segmented reading from an InputStream by delimiter.

## Constructor

`init(input: InputStream, boundaryBytes: Array<Byte>, halfBufferSize!: Int64 = 4096)`

## Methods

| Method | Signature | Description |
|------|------|------|
| indexOf | `func indexOf(bytes: Array<Byte>, from!: Int64): Int64` | Searches for a byte pattern; returns -1 when not found |
| addOffset | `func addOffset(off: Int64): Unit` | Advance the offset |
| read | `func read(bytes: Array<Byte>): (length: Int64, remainder: Bool, partEnd: Bool)` | Read into an array; returns (length, whether anything remains, whether the boundary was reached) |


A rotatable buffer supporting segmented reading from an InputStream by delimiter.

### MMapProt / MMapFlag / MSyncFlag / DEFAULT_MMAP_BYTES

> All declarations are available on Linux only: `@When[os == "Linux"]`

## MMapProt

```cj
@When[os == "Linux"]
public enum MMapProt
```

Memory mapping protection flags.

### Constructors

`Read` | `Write` | `Exec` | `None`

### Operators

| Operator | Signature | Description |
|--------|------|------|
| & | `operator func &(prot: IntNative): Bool` | Check a flag bit |
| \| | `operator func \|(other: MMapProt): Array<MMapProt>` | Combine two flags |
| \| | `operator func \|(others: Array<MMapProt>): Array<MMapProt>` | Combine arrays |

## MMapFlag

```cj
@When[os == "Linux"]
public enum MMapFlag <: Equatable<MMapFlag> & Equatable<IntNative>
```

### Constructors

`Shared` | `Private` | `Anonymous`

## MSyncFlag

```cj
@When[os == "Linux"]
public enum MSyncFlag
```

### Constructors

`Sync` | `Async` | `Invalidate`

## DEFAULT_MMAP_BYTES

```cj
@When[os == "Linux"]
public const DEFAULT_MMAP_BYTES = 1 * 1024 * 1024 * 1024  // 1 GiB
```

Default number of mapped bytes.


Memory-mapping related enum types and constants.

### BytePointerException / MMapException


## BytePointerException

```cj
public class BytePointerException <: BaseException
```

Package: `fountain::f_io.exception`

### Constructors

| Signature |
|------|
| `init()` |
| `init(message: String)` |
| `init(caused: Exception)` |
| `init(message: String, caused: Exception)` |

## MMapException

```cj
public class MMapException <: BaseException
```

Package: `fountain::f_io.exception`

### Constructors

| Signature |
|------|
| `init()` |
| `init(message: String)` |
| `init(caused: Exception)` |
| `init(message: String, caused: Exception)` |


The exception classes of the fountain::f_io.exception package.

### SegmentedLog

A write log with fixed-size segments and purely sequential appending. A general-purpose layer that takes over file I/O + rotation + synchronization. Reused by `f_store::WAL` and future MQ modules.

---

## API usage

### Configuration

```cj
let config = LogConfig(
    dir: "/tmp/mylog",          // Log directory
    filePrefix: "wal",          // File name prefix; produces "wal_1.log", "wal_2.log", ...
    maxFileSize: 64 * 1024 * 1024, // Maximum number of bytes per segment
    syncInterval: 10,           // Automatically fsync every 10 appends; <= 0 means sync every time
    startSeq!: 1,               // (named argument, default 1) Starting sequence number
    fileExt!: ".log"            // (named argument, default ".log") File extension
)
```

### Creating an instance

```cj
// Option one: generate the initial file name automatically, "{dir}/{filePrefix}_{startSeq}{fileExt}"
let log = SegmentedLog(config)

// Option two: specify the initial file path. rotate() still uses config to generate the following file names
let log = SegmentedLog(config, initPath: "/tmp/custom/path_1.log")
```

### Appending data

```cj
let data: Array<Byte> = ...
let pos: LogPosition = log.append(data)
// pos.seq    — segment sequence number
// pos.offset — offset within the segment (the starting byte position in that segment file)
```

The returned `LogPosition` can be used as a persistent token of the write position, for tracking the confirmation point during crash recovery.

### Forcing a flush

```cj
log.sync()  // fsync the current segment
```

### Manual rotation

```cj
log.rotate()  // Close the current segment and create a new one
```

Usually called after a checkpoint, together with `takeOldFiles()` to clean up old files.

### Getting the rotated files

```cj
let oldFiles = log.takeOldFiles()
// Returns ArrayList<String> containing the paths of all rotated old files
// The internal list is emptied after the call
```

The outside is responsible for deleting or archiving the returned old files.

### Reading the written segments sequentially

```cj
/**
 * Returns an InputStream that reads the data already written in all segments in order.
 * It closes itself when the reading is done. The caller can use DefaultCodec to stream-decode each entry.
 */
public func openEntryStream(): InputStream
```

### Closing the log

```cj
log.close()  // Implements the Resource interface, so try-with-resource can be used
```

---

## Design ideas and technical principles

### Design goals

The core requirements of SegmentedLog:

1. **Sequential appending** — write only, never read; written data hits disk immediately and no read API is provided
2. **Fixed-size segments** — a single file does not grow without bound and rotates automatically once the threshold is reached
3. **High performance** — minimize the number of user-space to kernel-space switches
4. **Cross-platform** — on Linux use mmap for zero-copy writes, elsewhere fall back to `file.write()`

### Architecture overview

```
SegmentedLog
 ├─ LogConfig        // Configuration (directory, prefix, size, sync interval, etc.)
 ├─ File (current)   // The file handle currently being written
 ├─ mmapPtr          // Linux: mmap mapping address; non-Linux: null
 ├─ State variables
 │   ├─ seq          // Current segment sequence number (AtomicInt64)
 │   ├─ currentSize  // Number of bytes already written in the current segment (AtomicInt64)
 │   ├─ appendCount  // Cumulative number of appends, used for periodic sync (AtomicInt64)
 │   └─ closed       // Closed flag (AtomicBool)
 ├─ oldFiles         // List of paths of rotated old files (ArrayList<String>)
 ├─ appendLock       // Mutex guarding the append + rotate critical section
 └─ oldFilesLock     // Mutex guarding concurrent access to oldFiles
```

### Write path (Linux)

```
User calls append(data)
  │
  ├─ closed check → throws LogClosedException when already closed
  │
  ├─ synchronized(appendLock) {
  │     ├─ (double check) closed checked again
  │     ├─ Overflow check: currentSize + data.size > maxFileSize → rotate automatically
  │     ├─ mcopy(mmapPtr + pos, data)    ← zero syscalls, writes the page cache directly
  │     ├─ currentSize += data.size
  │     └─ periodic sync → file.flush()    ← fsync flush
  │   }
  │
  └─ Returns LogPosition(seq, pos)
```

The core optimization is the `memcpy` into the mmap region: it triggers no system call, the data is written directly into the operating
system page cache, and the kernel writes the dirty pages back to disk asynchronously in the background. This "zero-syscall write" is the
basis of the high performance of SegmentedLog.

Non-Linux platforms fall back to `file.write(data)`, where every write goes through the `write()` system call.

### Rotation mechanism (rotate)

Triggered automatically when `currentSize + data.size > maxFileSize`; it can also be called manually:

```
doRotate()
  ├─ syncImpl()                          // Flush the current segment
  ├─ munmap(mmapPtr, maxFileSize)        // Unmap (Linux)
  ├─ file.close()                        // Close the current file
  ├─ oldFiles.add(curPath)               // Record the old path
  ├─ seq += 1
  ├─ File(newPath, ReadWrite)            // Create a new file
  ├─ ftruncate + fallocate + mmap        // Map the new file (Linux)
  └─ currentSize = 0, appendCount = 0
```

`startSeq` starts at 1 by default, and the file name format is `{prefix}_{seq}.{ext}`, such as `wal_1.log`, `wal_2.log`.

### Flush strategy

The `syncInterval` argument controls how often the automatic fsync happens:

- **syncInterval <= 0**: `file.flush()` runs after every `append`, maximizing data safety
- **syncInterval > 0**: `file.flush()` runs once every N appends. For example `syncInterval = 10` flushes after the 1st, 11th, 21st... append

`syncImpl()` calls `file.flush()` uniformly, which on Linux is equivalent to `msync()` + `fsync()`, writing the mmap dirty pages back to disk.

### Thread safety

SegmentedLog is thread safe, through the following mechanisms:

| Scenario | Protection mechanism |
|------|----------|
| append + rotate mutual exclusion | `appendLock` (Mutex) guards the whole critical section, including the overflow check, the write and the sync |
| Concurrent access to oldFiles | `oldFilesLock` (Mutex) guards `takeOldFiles()` and the add in `doRotate()` |
| Race between close and append | The `closed` flag uses a CAS on `AtomicBool` so that only the first call takes effect, and `synchronized(appendLock)` waits for an append in progress to finish |
| Visibility of state variables | `seq`, `currentSize` and `appendCount` all use `AtomicInt64`, and `Mutex` provides acquire/release semantics |

### Close protocol

```cj
public func close(): Unit {
    if (!closed.compareAndSwap(false, true)) { return }
    synchronized (appendLock) {
        syncImpl()
        unmapFile(mmapPtr, maxFileSize)   // Linux
        if (!file.isClosed()) { file.close() }
    }
}
```

Double-safety design:

1. **CAS** on the `closed` flag — ensures `close()` runs only once and later calls return immediately
2. **synchronized(appendLock)** — ensures there is no `append()` in progress, preventing close and writes from running concurrently
3. The final sync + unmapping + closing of the file happen inside the lock

### Cross-platform conditional compilation

| Method | Linux behavior | Non-Linux behavior |
|------|-----------|--------------|
| `initFileMapping` | `ftruncate + fallocate + mmap(MAP_SHARED)` | Returns `CPointer<Byte>()` (null) |
| `unmapFile` | `munmap(ptr, size)` | No-op |
| `writeImpl` | `memcpy(mmapPtr + pos, data)` — zero syscalls | `file.write(data)` |
| `syncImpl` | `file.flush()` — actually triggers `msync + fsync` | `file.flush()` |

### Relation to WAL

SegmentedLog was originally extracted as a general-purpose layer for `f_store::WAL` (Write-Ahead Log). The core constraints of a WAL match the
design of SegmentedLog exactly:

- **Sequential appending** — a WAL only appends and never modifies
- **Segmented management** — fixed-size files make it easy to delete old segments after a checkpoint
- **Configurable fsync frequency** — a WAL can trade off performance against durability
- **Crash recovery** — `LogPosition` can serve as the confirmation point, recording the segment and offset already written

### Usage pattern

A typical lifecycle:

```
1. Create the SegmentedLog
2. Loop append(data) ← rotates automatically
3. Checkpoint periodically
4. takeOldFiles() → delete the old files that have been checkpointed
5. close()
```

No read API is provided; reading is done by upper-layer modules (such as the recovery of WAL) which walk the old files by file name rule and
perform `pread` themselves.


A write log with fixed-size segments and purely sequential appending. On Linux it uses mmap for zero-syscall writes and elsewhere falls back to file.write(). Reused by modules such as WAL.


### ByteBuffer & SyncByteBuffer 

```cj
public class ByteBuffer <: IOStream {
    public ByteBuffer(
        initialCapacity!: Int64 = 32,
        public let toOverwriteOnClearing!: Bool = false
    )

    public init(
        array: Array<Byte>,
        toOverwriteOnClearing!: Bool = false
    )
    // Buffer capacity
    public prop capacity: Int64 
    
    // Buffer write position
    public prop writeOffset: Int64 
    // Buffer read position
    public prop readOffset: Int64 

    // Get the slice of unread bytes
    public func bytes(): Array<Byte> 
    // Set writeOffset and readOffset to 0; whether the data is cleared is decided by toOverwriteOnClearing
    public func clear(): Unit 
    public func clone(): ByteBuffer 
    // Grow the buffer; if capacity - writeOffset + readOffset >= addition, only the unread data is moved to the head of the buffer instead of growing it
    public func reserve(addition: Int64): Unit 
    // Move the read position of the buffer, ranging from the head of the buffer to writeOffset
    public func seekReading(pos: SeekPosition): Unit 
    // Move the write position of the buffer, ranging from readOffset to the end of the buffer
    public func seekWriting(pos: SeekPosition): Unit 
    // Read one byte; returns None immediately when there is no readable byte
    public func readByte(): ?Byte
    // Read a byte array; returns the number of bytes actually read, which is at most writeOffset - readOffset
    public func read(buf: Array<Byte>): Int64 
    // Write one byte; when the buffer is full it grows automatically by capacity/2 + buf.size
    public func writeByte(b: Byte): Unit 
    // Write into the buffer; when the writable space is insufficient it grows automatically by capacity/2 + buf.size
    public func write(buf: Array<Byte>): Unit 
    public func flush(): Unit {}
}

public class SyncByteBuffer <: IOStream {
    public init(
        initialCapacity!: Int64 = 32,
        toOverwriteOnClearing!: Bool = false
    )
    public init(
        array: Array<Byte>,
        toOverwriteOnClearing!: Bool = false
    )
    
    // Buffer capacity
    public prop capacity: Int64 
    // Buffer write position
    public prop writeOffset: Int64 
    // Buffer read position
    public prop readOffset: Int64 
    // Unsafe operation: returns the slice of all unread bytes of the buffer
    public unsafe func bytes(): Array<Byte> 
    // Only sets readOffset and writeOffset to 0; whether the data is cleared is decided by toOverwriteOnClearing
    public func clear(): Unit 
    public func clone(): ByteBuffer 
    // Grow the buffer; when the buffer is full it grows automatically by addition, if
    public func reserve(addition: Int64): Unit 
    // Change the read position of the buffer; the read range is from the head of the buffer to writeOffset
    public func seekReading(pos: SeekPosition): Unit 
    // Change the write position of the buffer; the write range is from readOffset to the end of the buffer
    public func seekWriting(pos: SeekPosition): Unit 
    // Read one byte; returns None immediately when there is no readable byte
    public func readByte(): ?Byte
    // Read one byte; when there is no readable byte it waits for timeout, and a timeout == Duration.Zero returns None<Byte> immediately
    // If there is still no readable byte after the timeout it returns None; if end() has been called it returns None
    public func readByte(timeout: Duration): ?Byte 
    // The number of bytes read is at most buf.size; when there is nothing readable it waits for timeout, and a timeout == Duration.Zero returns None<Int64> immediately
    // If there is still no readable byte after the timeout it returns None; if end() has been called it returns 0
    public func read(buf: Array<Byte>, timeout: Duration): ?Int64 
    // If there is nothing readable it returns 0 immediately
    public func read(buf: Array<Byte>): Int64 
    // Write one byte; when the buffer is full it grows automatically by capacity/2
    public func writeByte(b: Byte): Unit 
    // Write a byte array; when the buffer is full it grows automatically by capacity/2 + buf.size
    public func write(bytes: Array<Byte>): Unit 
    public func flush(): Unit {}
    // Call this function to confirm that no more bytes will be written
    public func end(): Unit 
    // Call fn inside a synchronized block, using the same lock instance as the other functions
    public func batch(fn: (ByteBuffer) -> Unit): Unit
}
```

### Extending Path
```cj
//Empty folders are ignored when copying
//to is the destination path of the copy and must be a Directory
//If the current path is a symbolic link, the target file of the link is read recursively before copying
//matched is a filter function; only source paths satisfying matched are copied
//srcPattern is a source path pattern; only file paths satisfying this pattern are copied. ** means a path of any level, * means any zero or more characters
//For matched and srcPattern, when the current path is a Directory, this check is performed for every file under it
public interface ExtendPath{
    func copy(to!: String): Unit 
    func copy(to!: Path): Unit
    func copy(srcPattern: String, to!: String): Unit 
    func copy(srcPattern: String, to!: Path): Unit
    func copy(to!: String, matched!: (Path) -> Bool): Unit 
    func copy(to!: Path, matched!: (Path) -> Bool): Unit
}
extend Path <: ExtendPath
```
