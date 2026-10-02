# fountain::f_io.uring API 参考

> 所有声明均标注 `@When[os == "Linux"]`，仅 Linux 可用

---

## 核心类

### IoUring

```cj
public class IoUring <: Resource
```

io_uring 高层封装，支持 try-with-resource。

#### 构造函数

| 签名 | 说明 |
|------|------|
| `init(entries: UInt32, flags!: UInt32 = 0)` | 基础初始化 |
| `init(entries: UInt32, params: IOUringParams)` | 带参数初始化 |

#### SQ 操作

| 方法 | 签名 | 说明 |
|------|------|------|
| getSQE | `func getSQE(): ?CPointer<IOUringSQE>` | 获取空闲 SQE |
| submit | `func submit(): Int32` | 提交 SQE |
| submitAndWait | `func submitAndWait(waitNr: UInt32): Int32` | 提交并等待 |

#### CQ 操作

| 方法 | 签名 | 说明 |
|------|------|------|
| waitCQE | `func waitCQE(): ?CPointer<IOUringCQE>` | 阻塞等待 CQE |
| peekCQE | `func peekCQE(): ?CPointer<IOUringCQE>` | 非阻塞查看 CQE |
| cqeSeen | `func cqeSeen(cqe: CPointer<IOUringCQE>): Unit` | 标记 CQE 已处理 |
| cqAdvance | `func cqAdvance(nr: UInt32): Unit` | 批量推进 CQ head |

#### 队列状态

| 方法 | 签名 |
|------|------|
| sqReady | `func sqReady(): UInt32` |
| sqSpaceLeft | `func sqSpaceLeft(): UInt32` |
| cqReady | `func cqReady(): UInt32` |

#### 注册

| 方法 | 签名 | 说明 |
|------|------|------|
| registerBuffers | `func registerBuffers(iovecs: CPointer<IOVec>, nr: UInt32): Int32` | 注册缓冲区 |
| unregisterBuffers | `func unregisterBuffers(): Int32` | 注销缓冲区 |
| registerFiles | `func registerFiles(files: CPointer<Int32>, nr: UInt32): Int32` | 注册文件描述符 |
| unregisterFiles | `func unregisterFiles(): Int32` | 注销文件描述符 |

#### 异步操作

| 方法 | 签名 | 说明 |
|------|------|------|
| getRegistry | `func getRegistry(): CompletionRegistry` | 获取完成注册表 |
| processCompletions | `func processCompletions(): UInt32` | 处理已完成操作 |
| waitAndProcess | `func waitAndProcess(): UInt32` | 等待并处理 |

---

### IoUringPool

```cj
public class IoUringPool <: Resource
```

io_uring 实例池，消除多线程 SQ 锁竞争。

#### 构造函数

`init(entriesPerRing: UInt32, ringCount!: Int64 = 4, flags!: UInt32 = 0)`

#### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| getRing | `func getRing(): IoUring` | 轮询获取 ring |
| getRing | `func getRing(index: Int64): IoUring` | 按索引获取 |
| count | `func count(): Int64` | ring 数量 |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | |

---

### IoUringParamsBuilder

```cj
public class IoUringParamsBuilder
```

IOUringParams 构建器，链式调用。

#### 方法（均返回 `IoUringParamsBuilder`）

`setSQPOLL` | `setSQPOLLIdle(ms)` | `setCQSize(size)` | `setSingleIssuer` | `setDeferTaskRun` | `setIOPoll` | `setSQAff(cpu)` | `setClamp` | `setAttachWQ(wqFd)` | `setSubmitAll` | `setCoopTaskRun` | `setSQE128` | `setCQE32`

最终调用 `build(): IOUringParams` 生成参数。

---

### RegisteredBuffers

```cj
public class RegisteredBuffers <: Resource
```

注册缓冲区，I/O 请求使用 READ_FIXED/WRITE_FIXED，内核跳过地址验证。

#### 构造函数

| 签名 | 说明 |
|------|------|
| `init(ring: IoUring, iovecs: CPointer<IOVec>, nrBuffers: UInt32)` | 密集注册 |
| `init(ring: IoUring, nrBuffers: UInt32, sparse!: Bool)` | 稀疏注册 |

#### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| update | `func update(index: UInt32, iovec: IOVec): Int32` | 更新指定索引（5.13+） |
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

注册文件描述符，减少内核查找开销。

#### 构造函数

| 签名 | 说明 |
|------|------|
| `init(ring: IoUring, nrFiles: UInt32)` | 密集注册 |
| `init(ring: IoUring, nrFiles: UInt32, sparse!: Bool)` | 稀疏注册 |

#### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| update | `func update(index: UInt32, fd: Int32): Int32` | 更新文件描述符 |
| updateBatch | `func updateBatch(offset: UInt32, fds: CPointer<Int32>, count: UInt32): Int32` | 批量更新 |
| allocIndex | `func allocIndex(fd: Int32): Int32` | 分配索引 |
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

Provided Buffer Ring 高层封装。

#### 构造函数

`init(ring: IoUring, nentries: UInt32, bgid!: Int32 = 0, flags!: UInt32 = 0)`

#### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| add | `func add(addr: UInt64, len: UInt32, bid: UInt16, bufOffset!: Int64 = 0): Unit` | 添加缓冲区 |
| advance | `func advance(count: UInt32): Unit` | 推进 tail |
| addAndAdvance | `func addAndAdvance(addr: UInt64, len: UInt32, bid: UInt16): Unit` | 添加并推进 |
| getBgid | `func getBgid(): Int32` | |
| getNentries | `func getNentries(): UInt32` | |
| getMask | `func getMask(): Int64` | |
| getTail | `func getTail(): UInt16` | |
| getBuf | `func getBuf(index: Int64): IOUringBuf` | |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | |

---

## 异步支持

### CompletionSlot

```cj
public interface CompletionSlot
```

类型擦除的异步完成槽位接口。

| 方法 | 签名 |
|------|------|
| complete | `func complete(cqe: CPointer<IOUringCQE>): Unit` |
| cancel | `func cancel(): Unit` |

### CompletionRegistry

```cj
public class CompletionRegistry
```

完成槽位注册表，映射 slotId 到 CompletionSlot。

| 方法 | 签名 | 说明 |
|------|------|------|
| nextId | `func nextId(): UInt64` | 生成下一个 ID |
| register | `func register(id: UInt64, slot: CompletionSlot): Unit` | 注册槽位 |
| completeSlot | `func completeSlot(id: UInt64, cqe: CPointer<IOUringCQE>): Unit` | 完成槽位 |
| cancelSlot | `func cancelSlot(id: UInt64): Unit` | 取消槽位 |
| size | `func size(): Int64` | |

### IoUringPromise<T>

```cj
public class IoUringPromise <: CompletionSlot
```

异步操作 Promise，Mutex + Condition 阻塞等待语义。

#### 构造函数

`init(slotId: UInt64, resultExtractor: (CPointer<IOUringCQE>) -> T)`

#### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| awaitResult | `func awaitResult(): T` | 阻塞等待结果 |
| awaitResult | `func awaitResult(timeout!: Duration): ?T` | 超时等待 |
| tryGetResult | `func tryGetResult(): ?T` | 非阻塞获取 |
| isCompleted | `func isCompleted(): Bool` | |
| isCancelled | `func isCancelled(): Bool` | |
| complete | `func complete(cqe: CPointer<IOUringCQE>): Unit` | |
| completeWithError | `func completeWithError(err: IoUringException): Unit` | |
| cancel | `func cancel(): Unit` | |

### IoUringFuture<T>

```cj
public class IoUringFuture
```

异步操作 Future，包装 IoUringPromise。

| 方法 | 签名 | 说明 |
|------|------|------|
| get | `func get(): T` | 阻塞获取 |
| get | `func get(timeout!: Duration): ?T` | 超时获取 |
| tryGet | `func tryGet(): ?T` | 非阻塞获取 |
| isCompleted | `func isCompleted(): Bool` | |
| isCancelled | `func isCancelled(): Bool` | |
| slotId | `func slotId(): UInt64` | |

---

## SQE 操作函数

### I/O 准备

| 函数 | 签名 | 说明 |
|------|------|------|
| ioUringPrepRead | `(sqe, fd, buf, nbytes, offset): Unit` | 准备读 |
| ioUringPrepWrite | `(sqe, fd, buf, nbytes, offset): Unit` | 准备写 |
| ioUringPrepReadFixed | `(sqe, fd, buf, nbytes, offset, bufIndex): Unit` | 准备读（注册缓冲区） |
| ioUringPrepWriteFixed | `(sqe, fd, buf, nbytes, offset, bufIndex): Unit` | 准备写（注册缓冲区） |
| ioUringPrepReadV | `(sqe, fd, iovecs, nrVecs, offset): Unit` | 准备向量读 |
| ioUringPrepWriteV | `(sqe, fd, iovecs, nrVecs, offset): Unit` | 准备向量写 |
| ioUringPrepFsync | `(sqe, fd, flags): Unit` | 准备文件同步 |
| ioUringPrepPollAdd | `(sqe, fd, pollMask): Unit` | 准备轮询 |
| ioUringPrepTimeout | `(sqe, ts, count, flags): Unit` | 准备超时 |
| ioUringPrepAccept | `(sqe, fd, addr, addrlen, flags): Unit` | 准备接受连接 |
| ioUringPrepConnect | `(sqe, fd, addr, addrlen): Unit` | 准备连接 |
| ioUringPrepSend | `(sqe, sockfd, buf, len, flags): Unit` | 准备发送 |
| ioUringPrepRecv | `(sqe, sockfd, buf, len, flags): Unit` | 准备接收 |
| ioUringPrepClose | `(sqe, fd): Unit` | 准备关闭 |
| ioUringPrepOpenAt | `(sqe, dfd, path, flags, mode): Unit` | 准备打开 |
| ioUringPrepCancel64 | `(sqe, userData, flags): Unit` | 准备取消 |
| ioUringPrepNop | `(sqe): Unit` | 准备空操作 |

### SQE 辅助

| 函数 | 签名 | 说明 |
|------|------|------|
| ioUringSQESetData64 | `(sqe, data: UInt64): Unit` | 设置 user data |
| ioUringSQESetFlags | `(sqe, flags: UInt8): Unit` | 设置 SQE 标志 |

---

## CQE 操作函数

| 函数 | 签名 | 说明 |
|------|------|------|
| ioUringCQEGetData64 | `(cqe): UInt64` | 获取 user data |
| ioUringCQEGetRes | `(cqe): Int32` | 获取结果值 |
| ioUringCQEGetFlags | `(cqe): UInt32` | 获取标志 |
| ioUringCQEGetBufferID | `(cqe): UInt16` | 提取 buffer ID |
| ioUringCQESeen | `(ring, cqe): Unit` | 标记 CQE 已处理 |
| ioUringCQAdvance | `(ring, nr: UInt32): Unit` | 批量推进 CQ head |
| ioUringCQReady | `(ring): UInt32` | 查询可用 CQE 数量 |
| ioUringSQReady | `(ring): UInt32` | 查询待提交 SQE 数量 |
| ioUringSQSpaceLeft | `(ring): UInt32` | 查询 SQ 剩余空间 |

---

## 内存屏障函数

| 函数 | 签名 | 说明 |
|------|------|------|
| ioUringSmpLoadAcquire | `(ptr: CPointer<UInt32>): UInt32` | Acquire 语义加载 |
| ioUringSmpStoreRelease | `(ptr: CPointer<UInt32>, value: UInt32): Unit` | Release 语义存储 |
| ioUringAtomicCAS | `(ptr, expected, desired): Bool` | 原子 CAS |
| ioUringLoadAcquire64 | `(ptr: CPointer<UInt64>): UInt64` | Acquire 语义加载 UInt64 |
| ioUringStoreRelease64 | `(ptr: CPointer<UInt64>, value: UInt64): Unit` | Release 语义存储 UInt64 |
| ioUringSmpMB | `(): Unit` | 全内存屏障 |
| ioUringSmpWMB | `(): Unit` | 写内存屏障 |
| ioUringSmpRMB | `(): Unit` | 读内存屏障 |

---

## 灵活数组辅助函数

### SQE cmd 操作

| 函数 | 签名 |
|------|------|
| sqeCmdPtr | `(sqe: CPointer<IOUringSQE>): CPointer<UInt8>` |
| sqeGetCmd | `(sqe, index: Int64): UInt8` |
| sqeSetCmd | `(sqe, index: Int64, value: UInt8): Unit` |
| sqeReadCmd | `(sqe, offset: Int64, length: Int64): Array<UInt8>` |
| sqeWriteCmd | `(sqe, offset: Int64, data: Array<UInt8>): Unit` |

### CQE big_cqe 操作

| 函数 | 签名 |
|------|------|
| cqeBigCQEPtr | `(cqe: CPointer<IOUringCQE>): CPointer<UInt64>` |
| cqeGetBigCQE | `(cqe, index: Int64): UInt64` |
| cqeSetBigCQE | `(cqe, index: Int64, value: UInt64): Unit` |

### Probe 操作

| 函数 | 签名 |
|------|------|
| probeOpsPtr | `(probe: CPointer<IOUringProbeHeader>): CPointer<IOUringProbeOp>` |
| probeGetOp | `(probe, index: Int64): IOUringProbeOp` |
| probeIsOpcodeSupported | `(probe, opcode: UInt8): Bool` |
| probeGetSupportedOpcodes | `(probe): Array<UInt8>` |
| probeGetOpsCount | `(probe): Int64` |
| probeGetLastOp | `(probe): UInt8` |

### Buffer Ring 操作

| 函数 | 签名 |
|------|------|
| bufRingBufsPtr | `(bufRing: CPointer<Unit>): CPointer<IOUringBuf>` |
| bufRingGetBuf | `(bufRing, index: Int64, ringEntries: UInt32): IOUringBuf` |
| bufRingSetBuf | `(bufRing, index: Int64, ringEntries: UInt32, addr, len, bid): Unit` |
| bufRingMask | `(ringEntries: UInt32): Int64` |
| bufRingInit | `(bufRing: CPointer<Unit>): Unit` |
| bufRingGetTail | `(bufRing: CPointer<Unit>): UInt16` |
| bufRingSetTail | `(bufRing: CPointer<Unit>, tail: UInt16): Unit` |

---

## FFI 辅助类

### SQECmdHelper

SQE cmd 灵活数组辅助。

| 静态成员 | 值 | 说明 |
|---------|-----|------|
| CMD_OFFSET | 48 | cmd 数组偏移 |
| CMD_MAX_SIZE | 80 | cmd 数组最大大小 |

### CQEBigHelper

CQE big_cqe 灵活数组辅助。

| 静态成员 | 值 |
|---------|-----|
| BIG_CQE_OFFSET | 16 |
| BIG_CQE_SIZE | 2 |

### ProbeOpsHelper

Probe ops 灵活数组辅助。

| 静态成员 | 值 |
|---------|-----|
| OPS_OFFSET | 16 |
| PROBE_OP_SIZE | 8 |

### BufRingHelper

BufRing bufs 灵活数组辅助。

| 静态成员 | 值 |
|---------|-----|
| BUFS_OFFSET | 0 |
| BUF_SIZE | 16 |

---

## 异常

### IoUringException

```cj
public class IoUringException <: Exception
```

构造函数: `init(message: String)`, `init(message: String, cause: Exception)`

---

## @C 结构体

| 结构体 | 说明 |
|--------|------|
| IOVec | I/O 向量：`iovBase: CPointer<Unit>`, `iovLen: UIntNative` |
| KernelTimespec | 内核时间：`tvSec: Int64`, `tvNsec: Int64` |
| IOUringSQE | 提交队列条目：`opcode`, `flags`, `fd`, `off`, `addr`, `len`, `userData`, `bufIndex` 等 |
| IOUringCQE | 完成队列条目：`userData: UInt64`, `res: Int32`, `flags: UInt32` |
| IOUringParams | 初始化参数：`sqEntries`, `cqEntries`, `flags`, `sqOff`, `cqOff` 等 |
| IOUring | liburing 主结构：`sq: IOUringSQ`, `cq: IOUringCQ`, `ringFd: Int32` 等 |
| IOUringBuf | 缓冲区条目：`addr`, `len`, `bid` |
| IOUringBufReg | 缓冲区注册：`ringAddr`, `ringEntries`, `bgid` |
| IOUringProbeHeader / IOUringProbeOp | 特性探测 |
| IOUringRsrcRegister / IOUringRsrcUpdate | 资源注册/更新 |
| IOUringSyncCancelReg | 同步取消注册 |
| IOSQRingOffsets / IOCQRingOffsets | SQ/CQ 环形队列偏移量 |

---

## 常量

定义在 `uring_constants.cj` 中，包括：

- **Setup 标志**: `IORING_SETUP_IOPOLL`, `IORING_SETUP_SQPOLL`, `IORING_SETUP_CQSIZE` 等
- **Enter 标志**: `IORING_ENTER_GETEVENTS` 等
- **SQE 标志**: `IOSQE_FIXED_FILE`, `IOSQE_IO_DRAIN`, `IOSQE_ASYNC` 等
- **CQE 标志**: `IORING_CQE_F_BUFFER`, `IORING_CQE_F_MORE` 等
- **操作码**: `IORING_OP_NOP`(0) ~ `IORING_OP_SENDMSG_ZC`(48)
- **特性标志**: `IORING_FEAT_SINGLE_MMAP` 等
- **其他**: `IORING_FSYNC_DATASYNC`, 超时标志, splice 标志, 注册操作码等

---

# fountain::f_io.uring.lockfree

无锁并发 io_uring 封装，基于 CAS + 原子操作。

## IoUringLockFree

```cj
public class IoUringLockFree <: Resource
```

端到端无锁并发 IoUring 封装，集成 AtomicSlotAllocator + CompletionSlotArray + SQEPreallocator + LockFreeCQEReaper。

### 构造函数

`init(ring: IoUring, slotCount!: UInt32 = 0)` — slotCount 默认为 ring.sqSpaceLeft()

### 提交路径

| 方法 | 签名 | 说明 |
|------|------|------|
| allocSlot | `func allocSlot(): ?UInt32` | 分配回调槽位 |
| releaseSlot | `func releaseSlot(slotIndex: UInt32): Unit` | 手动释放槽位 |
| getSQE | `func getSQE(slotIndex: UInt32): CPointer<IOUringSQE>` | 获取 SQE |
| setCallback | `func setCallback(slotIndex: UInt32, callback: CompletionCallback): UInt32` | 设置回调，返回 generation |
| encodeUserData | `func encodeUserData(slotIndex: UInt32, generation: UInt32): UInt64` | 编码 userData |
| commitSlot | `func commitSlot(slotIndex: UInt32): Unit` | 标记槽位就绪 |
| flush | `func flush(): Int32` | 提交所有已准备的 SQE |

### 收割路径

| 方法 | 签名 | 说明 |
|------|------|------|
| reap | `func reap(): UInt32` | 非阻塞收割所有 CQE |
| reapN | `func reapN(maxCount: UInt32): UInt32` | 收割最多 N 个 |
| waitAndReap | `func waitAndReap(): UInt32` | 阻塞等待并收割 |

### 便捷方法

| 方法 | 签名 | 说明 |
|------|------|------|
| submitAsync | `func submitAsync(prepFn: (CPointer<IOUringSQE>) -> Unit, callback: CompletionCallback): Bool` | 完整提交流程（Mutex 保护 getSQE+submit） |

---

## AtomicSlotAllocator

```cj
public class AtomicSlotAllocator
```

无锁原子槽位分配器，位图 + CAS 实现。

### 构造函数

`init(capacity: UInt32)` — 最大 32768

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| alloc | `func alloc(): ?UInt32` | CAS 分配空闲槽位 |
| release | `func release(slotId: UInt32): Unit` | 释放槽位 |
| isAllocated | `func isAllocated(slotId: UInt32): Bool` | |
| getCapacity | `func getCapacity(): UInt32` | |
| reset | `func reset(): Unit` | 重置（非线程安全） |

---

## CompletionSlotArray

```cj
public class CompletionSlotArray
```

无锁完成槽位数组，generation 计数器防止 ABA 问题。

### 构造函数

`init(slotCount: UInt32)` — 必须是 2 的幂，最大 2^24

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| setCallback | `func setCallback(slotIndex: UInt32, callback: CompletionCallback): UInt32` | 设置回调并递增 generation |
| getCallback | `func getCallback(slotIndex: UInt32): CompletionCallback` | |
| encodeUserData | `func encodeUserData(slotIndex: UInt32, generation: UInt32): UInt64` | 打包 [gen:slotIndex] |
| decodeUserData | `func decodeUserData(userData: UInt64): (UInt32, UInt32)` | 解包 (slotIndex, generation) |
| invokeAndRelease | `func invokeAndRelease(slotIndex: UInt32, generation: UInt32, cqe: CPointer<IOUringCQE>): Bool` | 调用回调并释放（校验 generation） |

---

## CompletionCallback

```cj
public open class CompletionCallback
```

无锁完成回调基类。

| 成员 | 签名 | 说明 |
|------|------|------|
| onComplete | `open func onComplete(cqe: CPointer<IOUringCQE>): Unit` | 完成时调用（默认空实现） |
| None | `static let None: CompletionCallback` | 空回调哨兵值 |

### LambdaCompletionCallback

```cj
public class LambdaCompletionCallback <: CompletionCallback
```

闭包包装回调。`init(action: (CPointer<IOUringCQE>) -> Unit)`

---

## SQEPreallocator

```cj
public class SQEPreallocator
```

无锁 SQE 预分配器。

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| allocSlot | `func allocSlot(): ?UInt32` | 分配 SQE 槽位 |
| getSQE | `func getSQE(index: UInt32): CPointer<IOUringSQE>` | 按索引获取 SQE |
| commitSlot | `func commitSlot(index: UInt32): Unit` | 标记就绪 |
| flush | `func flush(): Int32` | 提交 |
| pendingCount | `func pendingCount(): UInt32` | |
| preparedCount | `func preparedCount(): UInt32` | |

---

## LockFreeCQEReaper

```cj
public class LockFreeCQEReaper
```

无锁 CQE 收割器，直接操作 CQ head 指针。

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| peekCQE | `func peekCQE(): ?(CPointer<IOUringCQE>, UInt32)` | 非阻塞查看 |
| advance | `func advance(count: UInt32): Unit` | 推进 CQ head |
| reapAll | `func reapAll(handler: (CPointer<IOUringCQE>, UInt32) -> Unit): UInt32` | 收割所有 |
| reapN | `func reapN(maxCount: UInt32, handler: ...): UInt32` | 收割最多 N 个 |
| cqReady | `func cqReady(): UInt32` | |

---

## LockFreePromise

```cj
public class LockFreePromise <: CompletionCallback
```

轻量完成 Promise，AtomicBool + AtomicInt32 + 自旋 + Condition 回退。

| 方法 | 签名 | 说明 |
|------|------|------|
| onComplete | `override func onComplete(cqe: CPointer<IOUringCQE>): Unit` | 原子存储结果 |
| isCompleted | `func isCompleted(): Bool` | 无锁读取 |
| awaitResult | `func awaitResult(): Int32` | 自旋 + Condition 等待 |
