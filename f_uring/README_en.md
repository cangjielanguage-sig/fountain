# liburing ffi


## uring ffi api

> All declarations are annotated with `@When[os == "Linux"]` and are available on Linux only

---

## Core classes

### IoUring

```cj
public class IoUring <: Resource
```

A high-level wrapper around io_uring supporting try-with-resource.

#### Constructors

| Signature | Description |
|------|------|
| `init(entries: UInt32, flags!: UInt32 = 0)` | Basic initialization |
| `init(entries: UInt32, params: IOUringParams)` | Initialization with parameters |

#### SQ operations

| Method | Signature | Description |
|------|------|------|
| getSQE | `func getSQE(): ?CPointer<IOUringSQE>` | Get a free SQE |
| submit | `func submit(): Int32` | Submit SQEs |
| submitAndWait | `func submitAndWait(waitNr: UInt32): Int32` | Submit and wait |

#### CQ operations

| Method | Signature | Description |
|------|------|------|
| waitCQE | `func waitCQE(): ?CPointer<IOUringCQE>` | Block waiting for a CQE |
| peekCQE | `func peekCQE(): ?CPointer<IOUringCQE>` | Non-blocking peek at a CQE |
| cqeSeen | `func cqeSeen(cqe: CPointer<IOUringCQE>): Unit` | Mark a CQE as processed |
| cqAdvance | `func cqAdvance(nr: UInt32): Unit` | Advance the CQ head in bulk |

#### Queue status

| Method | Signature |
|------|------|
| sqReady | `func sqReady(): UInt32` |
| sqSpaceLeft | `func sqSpaceLeft(): UInt32` |
| cqReady | `func cqReady(): UInt32` |

#### Registration

| Method | Signature | Description |
|------|------|------|
| registerBuffers | `func registerBuffers(iovecs: CPointer<IOVec>, nr: UInt32): Int32` | Register buffers |
| unregisterBuffers | `func unregisterBuffers(): Int32` | Unregister buffers |
| registerFiles | `func registerFiles(files: CPointer<Int32>, nr: UInt32): Int32` | Register file descriptors |
| unregisterFiles | `func unregisterFiles(): Int32` | Unregister file descriptors |

#### Asynchronous operations

| Method | Signature | Description |
|------|------|------|
| getRegistry | `func getRegistry(): CompletionRegistry` | Get the completion registry |
| processCompletions | `func processCompletions(): UInt32` | Process completed operations |
| waitAndProcess | `func waitAndProcess(): UInt32` | Wait and process |

---

### IoUringPool

```cj
public class IoUringPool <: Resource
```

A pool of io_uring instances, eliminating SQ lock contention between threads.

#### Constructor

`init(entriesPerRing: UInt32, ringCount!: Int64 = 4, flags!: UInt32 = 0)`

#### Methods

| Method | Signature | Description |
|------|------|------|
| getRing | `func getRing(): IoUring` | Get a ring in round robin |
| getRing | `func getRing(index: Int64): IoUring` | Get a ring by index |
| count | `func count(): Int64` | Number of rings |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | |

---

### IoUringParamsBuilder

```cj
public class IoUringParamsBuilder
```

A builder for IOUringParams with chainable calls.

#### Methods (all return `IoUringParamsBuilder`)

`setSQPOLL` | `setSQPOLLIdle(ms)` | `setCQSize(size)` | `setSingleIssuer` | `setDeferTaskRun` | `setIOPoll` | `setSQAff(cpu)` | `setClamp` | `setAttachWQ(wqFd)` | `setSubmitAll` | `setCoopTaskRun` | `setSQE128` | `setCQE32`

Finally call `build(): IOUringParams` to produce the parameters.

---

### RegisteredBuffers

```cj
public class RegisteredBuffers <: Resource
```

Registered buffers: I/O requests use READ_FIXED/WRITE_FIXED and the kernel skips address validation.

#### Constructors

| Signature | Description |
|------|------|
| `init(ring: IoUring, iovecs: CPointer<IOVec>, nrBuffers: UInt32)` | Dense registration |
| `init(ring: IoUring, nrBuffers: UInt32, sparse!: Bool)` | Sparse registration |

#### Methods

| Method | Signature | Description |
|------|------|------|
| update | `func update(index: UInt32, iovec: IOVec): Int32` | Update the given index (5.13+) |
| getNrBuffers | `func getNrBuffers(): UInt32` | |
| isSparse | `func isSparse(): Bool` | |
| getIOVec | `func getIOVec(index: UInt32): IOVec` | |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | |

---

### RegisteredFiles

```cj
public class RegisteredFiles <: Resource
```

Registered file descriptors, reducing kernel lookup overhead.

#### Constructors

| Signature | Description |
|------|------|
| `init(ring: IoUring, nrFiles: UInt32)` | Dense registration |
| `init(ring: IoUring, nrFiles: UInt32, sparse!: Bool)` | Sparse registration |

#### Methods

| Method | Signature | Description |
|------|------|------|
| update | `func update(index: UInt32, fd: Int32): Int32` | Update a file descriptor |
| updateBatch | `func updateBatch(offset: UInt32, fds: CPointer<Int32>, count: UInt32): Int32` | Bulk update |
| allocIndex | `func allocIndex(fd: Int32): Int32` | Allocate an index |
| getNrFiles | `func getNrFiles(): UInt32` | |
| isSparse | `func isSparse(): Bool` | |
| getFd | `func getFd(index: UInt32): Int32` | |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | |

---

### IOUringBufferRing

```cj
public class IOUringBufferRing <: Resource
```

A high-level wrapper around the Provided Buffer Ring.

#### Constructor

`init(ring: IoUring, nentries: UInt32, bgid!: Int32 = 0, flags!: UInt32 = 0)`

#### Methods

| Method | Signature | Description |
|------|------|------|
| add | `func add(addr: UInt64, len: UInt32, bid: UInt16, bufOffset!: Int64 = 0): Unit` | Add a buffer |
| advance | `func advance(count: UInt32): Unit` | Advance the tail |
| addAndAdvance | `func addAndAdvance(addr: UInt64, len: UInt32, bid: UInt16): Unit` | Add and advance |
| getBgid | `func getBgid(): Int32` | |
| getNentries | `func getNentries(): UInt32` | |
| getMask | `func getMask(): Int64` | |
| getTail | `func getTail(): UInt16` | |
| getBuf | `func getBuf(index: Int64): IOUringBuf` | |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | |

---

## Asynchronous support

### CompletionSlot

```cj
public interface CompletionSlot
```

A type-erased asynchronous completion slot interface.

| Method | Signature |
|------|------|
| complete | `func complete(cqe: CPointer<IOUringCQE>): Unit` |
| cancel | `func cancel(): Unit` |

### CompletionRegistry

```cj
public class CompletionRegistry
```

The completion slot registry, mapping slotId to CompletionSlot.

| Method | Signature | Description |
|------|------|------|
| nextId | `func nextId(): UInt64` | Generate the next ID |
| register | `func register(id: UInt64, slot: CompletionSlot): Unit` | Register a slot |
| completeSlot | `func completeSlot(id: UInt64, cqe: CPointer<IOUringCQE>): Unit` | Complete a slot |
| cancelSlot | `func cancelSlot(id: UInt64): Unit` | Cancel a slot |
| size | `func size(): Int64` | |

### IoUringPromise<T>

```cj
public class IoUringPromise <: CompletionSlot
```

A Promise for asynchronous operations, with Mutex + Condition blocking-wait semantics.

#### Constructor

`init(slotId: UInt64, resultExtractor: (CPointer<IOUringCQE>) -> T)`

#### Methods

| Method | Signature | Description |
|------|------|------|
| awaitResult | `func awaitResult(): T` | Block waiting for the result |
| awaitResult | `func awaitResult(timeout!: Duration): ?T` | Wait with a timeout |
| tryGetResult | `func tryGetResult(): ?T` | Non-blocking get |
| isCompleted | `func isCompleted(): Bool` | |
| isCancelled | `func isCancelled(): Bool` | |
| complete | `func complete(cqe: CPointer<IOUringCQE>): Unit` | |
| completeWithError | `func completeWithError(err: IoUringException): Unit` | |
| cancel | `func cancel(): Unit` | |

### IoUringFuture<T>

```cj
public class IoUringFuture
```

A Future for asynchronous operations, wrapping IoUringPromise.

| Method | Signature | Description |
|------|------|------|
| get | `func get(): T` | Blocking get |
| get | `func get(timeout!: Duration): ?T` | Get with a timeout |
| tryGet | `func tryGet(): ?T` | Non-blocking get |
| isCompleted | `func isCompleted(): Bool` | |
| isCancelled | `func isCancelled(): Bool` | |
| slotId | `func slotId(): UInt64` | |

---

## SQE operation functions

### I/O preparation

| Function | Signature | Description |
|------|------|------|
| ioUringPrepRead | `(sqe, fd, buf, nbytes, offset): Unit` | Prepare a read |
| ioUringPrepWrite | `(sqe, fd, buf, nbytes, offset): Unit` | Prepare a write |
| ioUringPrepReadFixed | `(sqe, fd, buf, nbytes, offset, bufIndex): Unit` | Prepare a read (registered buffer) |
| ioUringPrepWriteFixed | `(sqe, fd, buf, nbytes, offset, bufIndex): Unit` | Prepare a write (registered buffer) |
| ioUringPrepReadV | `(sqe, fd, iovecs, nrVecs, offset): Unit` | Prepare a vectored read |
| ioUringPrepWriteV | `(sqe, fd, iovecs, nrVecs, offset): Unit` | Prepare a vectored write |
| ioUringPrepFsync | `(sqe, fd, flags): Unit` | Prepare a file sync |
| ioUringPrepPollAdd | `(sqe, fd, pollMask): Unit` | Prepare a poll |
| ioUringPrepTimeout | `(sqe, ts, count, flags): Unit` | Prepare a timeout |
| ioUringPrepAccept | `(sqe, fd, addr, addrlen, flags): Unit` | Prepare an accept |
| ioUringPrepConnect | `(sqe, fd, addr, addrlen): Unit` | Prepare a connect |
| ioUringPrepSend | `(sqe, sockfd, buf, len, flags): Unit` | Prepare a send |
| ioUringPrepRecv | `(sqe, sockfd, buf, len, flags): Unit` | Prepare a receive |
| ioUringPrepClose | `(sqe, fd): Unit` | Prepare a close |
| ioUringPrepOpenAt | `(sqe, dfd, path, flags, mode): Unit` | Prepare an open |
| ioUringPrepCancel64 | `(sqe, userData, flags): Unit` | Prepare a cancel |
| ioUringPrepNop | `(sqe): Unit` | Prepare a no-op |

### SQE helpers

| Function | Signature | Description |
|------|------|------|
| ioUringSQESetData64 | `(sqe, data: UInt64): Unit` | Set the user data |
| ioUringSQESetFlags | `(sqe, flags: UInt8): Unit` | Set the SQE flags |

---

## CQE operation functions

| Function | Signature | Description |
|------|------|------|
| ioUringCQEGetData64 | `(cqe): UInt64` | Get the user data |
| ioUringCQEGetRes | `(cqe): Int32` | Get the result value |
| ioUringCQEGetFlags | `(cqe): UInt32` | Get the flags |
| ioUringCQEGetBufferID | `(cqe): UInt16` | Extract the buffer ID |
| ioUringCQESeen | `(ring, cqe): Unit` | Mark a CQE as processed |
| ioUringCQAdvance | `(ring, nr: UInt32): Unit` | Advance the CQ head in bulk |
| ioUringCQReady | `(ring): UInt32` | Query the number of available CQEs |
| ioUringSQReady | `(ring): UInt32` | Query the number of SQEs waiting to be submitted |
| ioUringSQSpaceLeft | `(ring): UInt32` | Query the remaining SQ space |

---

## Memory barrier functions

| Function | Signature | Description |
|------|------|------|
| ioUringSmpLoadAcquire | `(ptr: CPointer<UInt32>): UInt32` | Load with acquire semantics |
| ioUringSmpStoreRelease | `(ptr: CPointer<UInt32>, value: UInt32): Unit` | Store with release semantics |
| ioUringAtomicCAS | `(ptr, expected, desired): Bool` | Atomic CAS |
| ioUringLoadAcquire64 | `(ptr: CPointer<UInt64>): UInt64` | Load a UInt64 with acquire semantics |
| ioUringStoreRelease64 | `(ptr: CPointer<UInt64>, value: UInt64): Unit` | Store a UInt64 with release semantics |
| ioUringSmpMB | `(): Unit` | Full memory barrier |
| ioUringSmpWMB | `(): Unit` | Write memory barrier |
| ioUringSmpRMB | `(): Unit` | Read memory barrier |

---

## Flexible array helper functions

### SQE cmd operations

| Function | Signature |
|------|------|
| sqeCmdPtr | `(sqe: CPointer<IOUringSQE>): CPointer<UInt8>` |
| sqeGetCmd | `(sqe, index: Int64): UInt8` |
| sqeSetCmd | `(sqe, index: Int64, value: UInt8): Unit` |
| sqeReadCmd | `(sqe, offset: Int64, length: Int64): Array<UInt8>` |
| sqeWriteCmd | `(sqe, offset: Int64, data: Array<UInt8>): Unit` |

### CQE big_cqe operations

| Function | Signature |
|------|------|
| cqeBigCQEPtr | `(cqe: CPointer<IOUringCQE>): CPointer<UInt64>` |
| cqeGetBigCQE | `(cqe, index: Int64): UInt64` |
| cqeSetBigCQE | `(cqe, index: Int64, value: UInt64): Unit` |

### Probe operations

| Function | Signature |
|------|------|
| probeOpsPtr | `(probe: CPointer<IOUringProbeHeader>): CPointer<IOUringProbeOp>` |
| probeGetOp | `(probe, index: Int64): IOUringProbeOp` |
| probeIsOpcodeSupported | `(probe, opcode: UInt8): Bool` |
| probeGetSupportedOpcodes | `(probe): Array<UInt8>` |
| probeGetOpsCount | `(probe): Int64` |
| probeGetLastOp | `(probe): UInt8` |

### Buffer Ring operations

| Function | Signature |
|------|------|
| bufRingBufsPtr | `(bufRing: CPointer<Unit>): CPointer<IOUringBuf>` |
| bufRingGetBuf | `(bufRing, index: Int64, ringEntries: UInt32): IOUringBuf` |
| bufRingSetBuf | `(bufRing, index: Int64, ringEntries: UInt32, addr, len, bid): Unit` |
| bufRingMask | `(ringEntries: UInt32): Int64` |
| bufRingInit | `(bufRing: CPointer<Unit>): Unit` |
| bufRingGetTail | `(bufRing: CPointer<Unit>): UInt16` |
| bufRingSetTail | `(bufRing: CPointer<Unit>, tail: UInt16): Unit` |

---

## FFI helper classes

### SQECmdHelper

Flexible array helper for the SQE cmd array.

| Static member | Value | Description |
|---------|-----|------|
| CMD_OFFSET | 48 | Offset of the cmd array |
| CMD_MAX_SIZE | 80 | Maximum size of the cmd array |

### CQEBigHelper

Flexible array helper for CQE big_cqe.

| Static member | Value |
|---------|-----|
| BIG_CQE_OFFSET | 16 |
| BIG_CQE_SIZE | 2 |

### ProbeOpsHelper

Flexible array helper for probe ops.

| Static member | Value |
|---------|-----|
| OPS_OFFSET | 16 |
| PROBE_OP_SIZE | 8 |

### BufRingHelper

Flexible array helper for BufRing bufs.

| Static member | Value |
|---------|-----|
| BUFS_OFFSET | 0 |
| BUF_SIZE | 16 |

---

## Exceptions

### IoUringException

```cj
public class IoUringException <: Exception
```

Constructors: `init(message: String)`, `init(message: String, cause: Exception)`

---

## @C structs

| Struct | Description |
|--------|------|
| IOVec | I/O vector: `iovBase: CPointer<Unit>`, `iovLen: UIntNative` |
| KernelTimespec | Kernel time: `tvSec: Int64`, `tvNsec: Int64` |
| IOUringSQE | Submission queue entry: `opcode`, `flags`, `fd`, `off`, `addr`, `len`, `userData`, `bufIndex`, etc. |
| IOUringCQE | Completion queue entry: `userData: UInt64`, `res: Int32`, `flags: UInt32` |
| IOUringParams | Initialization parameters: `sqEntries`, `cqEntries`, `flags`, `sqOff`, `cqOff`, etc. |
| IOUring | The main liburing structure: `sq: IOUringSQ`, `cq: IOUringCQ`, `ringFd: Int32`, etc. |
| IOUringBuf | Buffer entry: `addr`, `len`, `bid` |
| IOUringBufReg | Buffer registration: `ringAddr`, `ringEntries`, `bgid` |
| IOUringProbeHeader / IOUringProbeOp | Feature probing |
| IOUringRsrcRegister / IOUringRsrcUpdate | Resource registration/update |
| IOUringSyncCancelReg | Synchronous cancel registration |
| IOSQRingOffsets / IOCQRingOffsets | SQ/CQ ring queue offsets |

---

## Constants

Defined in `uring_constants.cj`, including:

- **Setup flags**: `IORING_SETUP_IOPOLL`, `IORING_SETUP_SQPOLL`, `IORING_SETUP_CQSIZE`, etc.
- **Enter flags**: `IORING_ENTER_GETEVENTS`, etc.
- **SQE flags**: `IOSQE_FIXED_FILE`, `IOSQE_IO_DRAIN`, `IOSQE_ASYNC`, etc.
- **CQE flags**: `IORING_CQE_F_BUFFER`, `IORING_CQE_F_MORE`, etc.
- **Opcodes**: `IORING_OP_NOP`(0) to `IORING_OP_SENDMSG_ZC`(48)
- **Feature flags**: `IORING_FEAT_SINGLE_MMAP`, etc.
- **Others**: `IORING_FSYNC_DATASYNC`, timeout flags, splice flags, registered opcodes, etc.

---

# fountain::f_uring.lockfree

A lock-free concurrent io_uring wrapper based on CAS + atomic operations.

## IoUringLockFree

```cj
public class IoUringLockFree <: Resource
```

An end-to-end lock-free concurrent IoUring wrapper integrating AtomicSlotAllocator + CompletionSlotArray + SQEPreallocator + LockFreeCQEReaper.

### Constructor

`init(ring: IoUring, slotCount!: UInt32 = 0)` — slotCount defaults to ring.sqSpaceLeft()

### Submission path

| Method | Signature | Description |
|------|------|------|
| allocSlot | `func allocSlot(): ?UInt32` | Allocate a callback slot |
| releaseSlot | `func releaseSlot(slotIndex: UInt32): Unit` | Release a slot manually |
| getSQE | `func getSQE(slotIndex: UInt32): CPointer<IOUringSQE>` | Get the SQE |
| setCallback | `func setCallback(slotIndex: UInt32, callback: CompletionCallback): UInt32` | Set the callback and return the generation |
| encodeUserData | `func encodeUserData(slotIndex: UInt32, generation: UInt32): UInt64` | Encode the userData |
| commitSlot | `func commitSlot(slotIndex: UInt32): Unit` | Mark the slot as ready |
| flush | `func flush(): Int32` | Submit all prepared SQEs |

### Reaping path

| Method | Signature | Description |
|------|------|------|
| reap | `func reap(): UInt32` | Reap all CQEs without blocking |
| reapN | `func reapN(maxCount: UInt32): UInt32` | Reap at most N |
| waitAndReap | `func waitAndReap(): UInt32` | Block waiting and reap |

### Convenience methods

| Method | Signature | Description |
|------|------|------|
| submitAsync | `func submitAsync(prepFn: (CPointer<IOUringSQE>) -> Unit, callback: CompletionCallback): Bool` | The complete submission flow (getSQE + submit guarded by a Mutex) |

---

## AtomicSlotAllocator

```cj
public class AtomicSlotAllocator
```

A lock-free atomic slot allocator implemented with a bitmap + CAS.

### Constructor

`init(capacity: UInt32)` — at most 32768

### Methods

| Method | Signature | Description |
|------|------|------|
| alloc | `func alloc(): ?UInt32` | Allocate a free slot with CAS |
| release | `func release(slotId: UInt32): Unit` | Release a slot |
| isAllocated | `func isAllocated(slotId: UInt32): Bool` | |
| getCapacity | `func getCapacity(): UInt32` | |
| reset | `func reset(): Unit` | Reset (not thread safe) |

---

## CompletionSlotArray

```cj
public class CompletionSlotArray
```

A lock-free completion slot array whose generation counter prevents ABA problems.

### Constructor

`init(slotCount: UInt32)` — must be a power of two, at most 2^24

### Methods

| Method | Signature | Description |
|------|------|------|
| setCallback | `func setCallback(slotIndex: UInt32, callback: CompletionCallback): UInt32` | Set the callback and increment the generation |
| getCallback | `func getCallback(slotIndex: UInt32): CompletionCallback` | |
| encodeUserData | `func encodeUserData(slotIndex: UInt32, generation: UInt32): UInt64` | Pack [gen:slotIndex] |
| decodeUserData | `func decodeUserData(userData: UInt64): (UInt32, UInt32)` | Unpack (slotIndex, generation) |
| invokeAndRelease | `func invokeAndRelease(slotIndex: UInt32, generation: UInt32, cqe: CPointer<IOUringCQE>): Bool` | Invoke the callback and release (validating the generation) |

---

## CompletionCallback

```cj
public open class CompletionCallback
```

Base class of lock-free completion callbacks.

| Member | Signature | Description |
|------|------|------|
| onComplete | `open func onComplete(cqe: CPointer<IOUringCQE>): Unit` | Called on completion (empty implementation by default) |
| None | `static let None: CompletionCallback` | Sentinel value for an empty callback |

### LambdaCompletionCallback

```cj
public class LambdaCompletionCallback <: CompletionCallback
```

A callback wrapping a closure. `init(action: (CPointer<IOUringCQE>) -> Unit)`

---

## SQEPreallocator

```cj
public class SQEPreallocator
```

A lock-free SQE pre-allocator.

### Methods

| Method | Signature | Description |
|------|------|------|
| allocSlot | `func allocSlot(): ?UInt32` | Allocate an SQE slot |
| getSQE | `func getSQE(index: UInt32): CPointer<IOUringSQE>` | Get an SQE by index |
| commitSlot | `func commitSlot(index: UInt32): Unit` | Mark as ready |
| flush | `func flush(): Int32` | Submit |
| pendingCount | `func pendingCount(): UInt32` | |
| preparedCount | `func preparedCount(): UInt32` | |

---

## LockFreeCQEReaper

```cj
public class LockFreeCQEReaper
```

A lock-free CQE reaper operating directly on the CQ head pointer.

### Methods

| Method | Signature | Description |
|------|------|------|
| peekCQE | `func peekCQE(): ?(CPointer<IOUringCQE>, UInt32)` | Non-blocking peek |
| advance | `func advance(count: UInt32): Unit` | Advance the CQ head |
| reapAll | `func reapAll(handler: (CPointer<IOUringCQE>, UInt32) -> Unit): UInt32` | Reap everything |
| reapN | `func reapN(maxCount: UInt32, handler: ...): UInt32` | Reap at most N |
| cqReady | `func cqReady(): UInt32` | |

---

## LockFreePromise

```cj
public class LockFreePromise <: CompletionCallback
```

A lightweight completion Promise: AtomicBool + AtomicInt32 + spinning + Condition fallback.

| Method | Signature | Description |
|------|------|------|
| onComplete | `override func onComplete(cqe: CPointer<IOUringCQE>): Unit` | Atomically store the result |
| isCompleted | `func isCompleted(): Bool` | Lock-free read |
| awaitResult | `func awaitResult(): Int32` | Spin + Condition wait |


## IOUringStream
A uring wrapper implementing std.io.IOStream 

> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public class IOUringStream <: IOStream & Resource
```

Package: `fountain::f_io`

An IOStream implementation based on io_uring (dual ring architecture). Write returns immediately after an asynchronous submission, while Read does submit + waitCQE on the same thread. An optional registered buffer mode is available.

## Constructors

| Signature | Description |
|------|------|
| `init(fd: Int32, entries: UInt32, flags!: UInt32 = 0, fixedBufCount!: UInt32 = 0, fixedBufSize!: UInt32 = 4096)` | Full arguments, supporting registered buffers |
| `init(fd: Int32)` | Simplified initialization (64 entries, no registered buffers) |

## Methods

| Method | Signature | Description |
|------|------|------|
| read | `func read(buffer: Array<Byte>): Int64` | Read data; blocks when there is no data and returns immediately when there is |
| write | `func write(buffer: Array<Byte>): Unit` | Write data and return immediately |
| flush | `func flush(): Unit` | No-op (write already returns immediately) |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | Stop the reaper thread, unregister the buffers and close the ring |


## liburing&file_perf

## Test environment

- **Platform**: WSL2 Linux (tmpfs)
- **Data volume**: 1MB (256 × 4KB)
- **Cangjie version**: 1.1.0-alpha
- **IOUringStream architecture**: dual ring + background reaping thread + zero-allocation write

## Performance overview

| Operation | IOUringStream | std.fs.File | Comparison |
|------|-------------|------------|------|
| Write 1MB | **290us** | 391us | IOUring is 26% faster |
| Read 1MB | 447us | **101us** | File is 4.4× faster |
| FixedBuf Write 1MB | 552us | 391us | File is 41% faster |
| FixedBuf Read 1MB | 680us | 101us | File is 6.7× faster |

## Write performance analysis

IOUringStream Write is 26% faster than File because:

- **Asynchronous submission**: write() returns immediately after submitting the SQE without waiting for completion
- **Background reaping**: a separate thread reaps CQEs and does not block the calling thread
- **Zero allocation**: the write path creates no LambdaCompletionCallback and uses CompletionCallback.None

## Root cause analysis of the Read performance gap

### Micro-benchmark breakdown (256 × 4KB reads, tmpfs)

| Operation | Time per call | Share |
|------|--------|------|
| getSQE | 60ns | 7% |
| acquireBuf | 49ns | 6% |
| prepRead + setData64 | 85ns | 10% |
| **submit (syscall)** | **467ns** | **58%** |
| waitCQE | 64ns | 8% |
| cqeSeen | 83ns | 10% |
| Mutex | 23ns | Negligible |

### Root cause

**The submit syscall accounts for 58% of the time of the read path.** On tmpfs the read latency is extremely low (the CQE is available almost
immediately after submit returns), so the two kernel interactions of io_uring (submit + waitCQE = 531ns) become the bottleneck instead. File.read
needs only 1 syscall (365ns).

### Optimizations that have been ruled out

| Approach | Result | Reason |
|------|------|------|
| Merging the syscalls with submitAndWait | Slower (934ns vs 811ns/iter) | The kernel path is longer |
| SQPOLL | No effect | The submit overhead is already small on tmpfs |
| Removing readMutex | Negligible | The Mutex overhead is only 23ns/iter |
| Registered Buffers | Slower | The extra memcpy overhead outweighs the saving on address validation |
| LockFreePromise (spin waiting) | No effect | The tmpfs CQE latency exceeds the spin window |
| Dual ring architecture | Read dropped from 12ms to 447us | Eliminates the cross-thread Condition notification |

### Conclusion

io_uring is inherently slower than a direct syscall in the **synchronous read + low-latency storage** scenario; this is an architectural
trade-off. The advantage of io_uring lies in **asynchronous + batched I/O** scenarios.

## Optimization history

| Version | Write | Read | Key change |
|------|-------|------|---------|
| Initial (submitAsync + sleep) | 2589ms | - | Polled CQEs every 1ms |
| waitAndReap instead of sleep | 8ms | - | 323× Write improvement |
| Background reaping thread + IoUringPromise | 0ms | 12ms | Asynchronous write + Condition notification |
| Dual ring architecture | 381us | 439us | Eliminates cross-thread notification |
| Zero-allocation write | 278us | 447us | Fixed a double-free bug |
| Current (ns precision) | 290us | 447us | - |

## Registered Buffers test

Registered buffers are pre-registered into the kernel with `io_uring_register_buffers`; I/O requests use the READ_FIXED/WRITE_FIXED opcodes and the
kernel skips address validation.

### Test results

| Operation | Normal mode | Registered buffer mode | Change |
|------|---------|-------------|------|
| Write | 290us | 552us | +90% |
| Read | 447us | 680us | +52% |

### Analysis

On tmpfs the kernel address validation overhead is extremely small (<0.1us per call), so the extra memcpy (4KB per call × 256 calls) is a
net loss. Registered buffers are better suited to real block devices (NVMe SSD) with frequent small I/O.
