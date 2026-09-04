# f_io

仓颉 I/O 工具库，提供内存映射、流式 I/O 等功能。

## 文档

### pipe / asyncPipe / copyToCType

## pipe

```cj
public func pipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

将 `input` 的所有数据通过缓冲区传输到 `output`。

## asyncPipe

```cj
public func asyncPipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit
    where I <: InputStream, O <: OutputStream
```

在新线程中执行 `pipe`。

## copyToCType

```cj
public func copyToCType<T>(input: InputStream): T where T <: CType
```

从 `InputStream` 读取 `sizeOf<T>()` 字节并解释为 CType 值。字节数不足时抛出 `IllegalSizeException`。


顶级工具函数：数据管道、异步管道、InputStream 转 CType。

### BytePointerStream


```cj
public class BytePointerStream <: IOStream & Resource
```

基于原生内存指针的字节流，支持读写 CPointer<Byte> 和 Array<Byte>。

## 构造函数

| 签名 | 说明 |
|------|------|
| `init(pointer: CPointer<Byte>, size: Int64, readable!: Bool = true, writable!: Bool = true)` | 基于已有指针 |
| `init(size: Int64, readable!: Bool = true, writable!: Bool = true)` | 分配新内存（LibC.malloc） |

## 属性

| 名称 | 类型 | 说明 |
|------|------|------|
| `readable` | `Bool` | 是否可读 |
| `writable` | `Bool` | 是否可写 |
| `readOffset` | `Int64` | 读偏移量 |
| `writeOffset` | `Int64` | 写偏移量 |
| `length` | `Int64` | 总映射大小 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(p: CPointer<Byte>, maxSize: Int64): Int64` | 读入 CPointer |
| read | `func read(buffer: Array<Byte>): Int64` | 读入 Array |
| write | `func write(p: CPointer<Byte>, size: Int64): Unit` | 从 CPointer 写入，空间不足抛异常 |
| write | `func write(buffer: Array<Byte>): Unit` | 从 Array 写入，空间不足抛异常 |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | 释放内存（如 freeable） |


基于原生内存指针的字节流，支持读写 `CPointer<Byte>` 和 `Array<Byte>`。

### DummyInputStream


```cj
public class DummyInputStream <: InputStream & Resource
```

空输入流，用于测试或占位。

## 静态常量

| 名称 | 说明 |
|------|------|
| `THROW_ON_ACCESSING` | read 时抛异常 |
| `SILENCE` | read 时返回 0 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| read | `func read(buffer: Array<Byte>): Int64` | 取决于 throwing 标志 |
| isClosed | `func isClosed(): Bool` | 始终返回 false |
| close | `func close(): Unit` | 无操作 |


空输入流，用于测试或占位。

### DummyOutputStream


```cj
public class DummyOutputStream <: OutputStream & Resource
```

空输出流，用于测试或占位。

## 静态常量

| 名称 | 说明 |
|------|------|
| `THROW_ON_ACCESSING` | write/flush 时抛异常 |
| `SILENCE` | 静默忽略 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| write | `func write(buffer: Array<Byte>): Unit` | 取决于 throwing 标志 |
| flush | `func flush(): Unit` | 取决于 throwing 标志 |
| isClosed | `func isClosed(): Bool` | 始终返回 false |
| close | `func close(): Unit` | 无操作 |


空输出流，用于测试或占位。

### ExtendByteBuffer


```cj
public interface ExtendByteBuffer
```

ByteBuffer 的类型化读写接口，支持大端/小端字节序。

## 方法

| 分类 | 方法 | 返回类型 |
|------|------|---------|
| 读 | `readBool/readUInt8/readUInt16/readUInt32/readUInt64/readInt8/readInt16/readInt32/readInt64/readFloat16/readFloat32/readFloat64` | `?T` |
| 写 | `writeBool/writeUInt8/writeUInt16/writeUInt32/writeUInt64/writeInt8/writeInt16/writeInt32/writeInt64/writeFloat16/writeFloat32/writeFloat64` | `Unit` |

所有方法均有 `endian!: Endian` 参数（默认 `Endian.Platform`）。

## 扩展

```cj
extend ByteBuffer <: ExtendByteBuffer
```

`std.io.ByteBuffer` 实现了 `ExtendByteBuffer`。

ByteBuffer 的类型化读写接口，支持大端/小端字节序。

### MMapFile


> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public class MMapFile <: Resource & IOStream
```

内存映射文件。写映射区每次重定位为 mapLength 大小，读映射区按 mapLength 和剩余长度动态决定。文件以只写方式打开且长度不足时会自动延长。

## 构造函数

| 签名 | 说明 |
|------|------|
| `init(file: File, prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, offset!: Int64 = 0, mapLength!: Int64 = DEFAULT_MMAP_BYTES)` | 基于文件映射 |
| `static func anonymous(prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, mapLength!: Int64 = DEFAULT_MMAP_BYTES): MMapFile` | 匿名映射 |

## 属性

| 名称 | 类型 | 说明 |
|------|------|------|
| `info` | `FileInfo` | 文件信息 |
| `isReadable` | `Bool` | 是否可读 |
| `isWritable` | `Bool` | 是否可写 |
| `isSyncable` | `Bool` | 是否可同步（非 Private 且非 Anonymous） |
| `isAnonymous` | `Bool` | 是否匿名映射 |
| `readOffset` | `Int64` | 读偏移量 |
| `writeOffset` | `Int64` | 写偏移量 |
| `length` | `Int64` | 映射内存大小 |

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| syncAndUnmap | `func syncAndUnmap(): Unit` | 同步并取消映射 |
| sync | `func sync(flag: MSyncFlag): Unit` | 按标志同步 |
| remap | `func remap(offset: Int64, mapLength!: Int64, flag!: MMapFlag): MMapFile` | 重新映射 |
| setLength | `func setLength(length!: Int64): Unit` | 设置文件长度 |
| read | `func read(p: CPointer<Byte>, maxSize: Int64): Int64` | |
| read | `func read(buffer: Array<Byte>): Int64` | |
| write | `func write(p: CPointer<Byte>, s: Int64): Unit` | |
| write | `func write(buffer: Array<Byte>): Unit` | |
| flush | `func flush(): Unit` | 等同于 sync(MSyncFlag.Sync) |
| isClosed | `func isClosed(): Bool` | |
| close | `func close(): Unit` | sync + unmap + close file |

## 相关类型

- ToMMap — 接口，File 扩展此接口
- MMapProt — 保护标志枚举
- MMapFlag — 映射标志枚举
- MSyncFlag — 同步标志枚举


内存映射文件，支持读写映射、同步、重映射。

### ToMMap


> `@When[os == "Linux"]`

```cj
@When[os == "Linux"]
public interface ToMMap
```

## 方法

| 方法 | 签名 |
|------|------|
| mmap | `func mmap(offset: Int64, mapLength: Int64, flag!: MMapFlag): MMapFile` |

## 扩展

```cj
@When[os == "Linux"]
extend File <: ToMMap
```

`std.fs.File` 扩展了 `ToMMap`，根据 `canRead()`/`canWrite()` 确定 prots。


接口，std.fs.File 扩展此接口以创建 MMapFile。

### QueueInputStream / NonblockingQueueStream / BlockingQueueStream

## QueueInputStream

```cj
sealed abstract class QueueInputStream <: InputStream
```

队列式输入流，支持添加多个 InputStream 顺序读取。

### 构造函数

`init(size: Int64, closeOnEnd!: Bool = true)`

### 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| add | `func add(stream: InputStream): Unit` | 添加输入流 |
| add | `func add(bytes: Array<Byte>): Unit` | 添加字节（包装为 ByteBuffer） |

## NonblockingQueueStream

```cj
public class NonblockingQueueStream <: QueueInputStream
```

非阻塞读取，无数据时返回 0。

## BlockingQueueStream

```cj
public class BlockingQueueStream <: QueueInputStream
```

阻塞读取，等待数据可用。


队列式输入流，支持添加多个 InputStream 顺序读取。

### RotatableBuffer

```cj
public class RotatableBuffer
```

可旋转缓冲区，支持按分隔符从 InputStream 中分段读取。

## 构造函数

`init(input: InputStream, boundaryBytes: Array<Byte>, halfBufferSize!: Int64 = 4096)`

## 方法

| 方法 | 签名 | 说明 |
|------|------|------|
| indexOf | `func indexOf(bytes: Array<Byte>, from!: Int64): Int64` | 搜索字节模式，未找到返回 -1 |
| addOffset | `func addOffset(off: Int64): Unit` | 推进偏移量 |
| read | `func read(bytes: Array<Byte>): (length: Int64, remainder: Bool, partEnd: Bool)` | 读取到数组，返回（长度，是否有剩余，是否到达边界） |


可旋转缓冲区，支持按分隔符从 InputStream 中分段读取。

### MMapProt / MMapFlag / MSyncFlag / DEFAULT_MMAP_BYTES

> 所有声明仅 Linux 可用：`@When[os == "Linux"]`

## MMapProt

```cj
@When[os == "Linux"]
public enum MMapProt
```

内存映射保护标志。

### 构造器

`Read` | `Write` | `Exec` | `None`

### 操作符

| 操作符 | 签名 | 说明 |
|--------|------|------|
| & | `operator func &(prot: IntNative): Bool` | 检查标志位 |
| \| | `operator func \|(other: MMapProt): Array<MMapProt>` | 组合两个标志 |
| \| | `operator func \|(others: Array<MMapProt>): Array<MMapProt>` | 组合数组 |

## MMapFlag

```cj
@When[os == "Linux"]
public enum MMapFlag <: Equatable<MMapFlag> & Equatable<IntNative>
```

### 构造器

`Shared` | `Private` | `Anonymous`

## MSyncFlag

```cj
@When[os == "Linux"]
public enum MSyncFlag
```

### 构造器

`Sync` | `Async` | `Invalidate`

## DEFAULT_MMAP_BYTES

```cj
@When[os == "Linux"]
public const DEFAULT_MMAP_BYTES = 1 * 1024 * 1024 * 1024  // 1 GiB
```

默认映射字节数。


内存映射相关的枚举类型和常量。

### BytePointerException / MMapException


## BytePointerException

```cj
public class BytePointerException <: BaseException
```

包: `fountain::f_io.exception`

### 构造函数

| 签名 |
|------|
| `init()` |
| `init(message: String)` |
| `init(caused: Exception)` |
| `init(message: String, caused: Exception)` |

## MMapException

```cj
public class MMapException <: BaseException
```

包: `fountain::f_io.exception`

### 构造函数

| 签名 |
|------|
| `init()` |
| `init(message: String)` |
| `init(caused: Exception)` |
| `init(message: String, caused: Exception)` |


fountain::f_io.exception 包的异常类。

### SegmentedLog

固定大小分段、纯顺序追加的写日志。通用层，接管文件 I/O + 轮转 + 同步。供 `f_store::WAL` 和未来 MQ 模块复用。

---

## API 使用说明

### 配置

```cj
let config = LogConfig(
    dir: "/tmp/mylog",          // 日志目录
    filePrefix: "wal",          // 文件名前缀，生成 "wal_1.log", "wal_2.log", ...
    maxFileSize: 64 * 1024 * 1024, // 每个 segment 最大字节数
    syncInterval: 10,           // 每 10 次 append 自动 fsync；<= 0 表示每次都 sync
    startSeq!: 1,               // (命名参数，默认 1) 起始 sequence 号
    fileExt!: ".log"            // (命名参数，默认 ".log") 文件扩展名
)
```

### 创建实例

```cj
// 方式一：自动生成初始文件名 "{dir}/{filePrefix}_{startSeq}{fileExt}"
let log = SegmentedLog(config)

// 方式二：指定初始文件路径。rotate() 时仍使用 config 生成后续文件名
let log = SegmentedLog(config, initPath: "/tmp/custom/path_1.log")
```

### 追加数据

```cj
let data: Array<Byte> = ...
let pos: LogPosition = log.append(data)
// pos.seq   — segment 序号
// pos.offset — 段内偏移（该 segment 文件中的起始字节位置）
```

返回的 `LogPosition` 可用作写入位置的持久化凭证，用于崩溃恢复时的确认点追踪。

### 强制刷盘

```cj
log.sync()  // fsync 当前 segment
```

### 主动轮转

```cj
log.rotate()  // 关闭当前 segment 并创建新 segment
```

通常在 checkpoint 后调用，配合 `takeOldFiles()` 清理旧文件。

### 获取已轮转的文件

```cj
let oldFiles = log.takeOldFiles()
// 返回 ArrayList<String>，包含所有已轮转的旧文件路径
// 调用后内部列表被清空
```

外部负责对返回的旧文件执行删除或归档操作。

### 顺序读取已写入的segment

```cj
/**
 * 返回一个 InputStream，依次读取所有 segment 中已写入的数据。
 * 读完后自动关闭。调用方可用 DefaultCodec 流式解码每条 entry。
 */
public func openEntryStream(): InputStream
```

### 关闭日志

```cj
log.close()  // 实现 Resource 接口，可用 try-with-resource
```

---

## 实现思想与技术原理

### 设计目标

SegmentedLog 的核心需求：

1. **顺序追加** — 只写不读，写入即落盘，不提供读取 API
2. **固定大小分段** — 单文件不无限增长，到达阈值后自动轮转
3. **高性能** — 最小化用户态到内核态的切换次数
4. **跨平台** — Linux 用 mmap 零拷贝写入，非 Linux 回退 `file.write()`

### 架构概览

```
SegmentedLog
 ├─ LogConfig        // 配置参数（目录、前缀、大小、sync 间隔等）
 ├─ File (当前)       // 当前写入的文件句柄
 ├─ mmapPtr          // Linux: mmap 映射地址；非 Linux: null
 ├─ 状态变量
 │   ├─ seq          // 当前 segment 序号（AtomicInt64）
 │   ├─ currentSize  // 当前 segment 已写入字节数（AtomicInt64）
 │   ├─ appendCount  // 累计 append 次数，用于周期性 sync（AtomicInt64）
 │   └─ closed       // 关闭标志（AtomicBool）
 ├─ oldFiles         // 已轮转的旧文件路径列表（ArrayList<String>）
 ├─ appendLock       // Mutex，保护 append + rotate 临界区
 └─ oldFilesLock     // Mutex，保护 oldFiles 并发访问
```

### 写入路径（Linux）

```
用户调用 append(data)
  │
  ├─ closed 检查 → 已关闭则抛 LogClosedException
  │
  ├─ synchronized(appendLock) {
  │     ├─ (双层检查) closed 重检
  │     ├─ 超限检查: currentSize + data.size > maxFileSize → 自动 rotate
  │     ├─ mcopy(mmapPtr + pos, data)    ← 零 syscall，直接写 page cache
  │     ├─ currentSize += data.size
  │     └─ 周期性 sync → file.flush()    ← fsync 刷盘
  │   }
  │
  └─ 返回 LogPosition(seq, pos)
```

核心优化在于 `memcpy` 到 `mmap` 区域这一操作：它不触发任何系统调用，数据直接写入操作系统的 page cache，内核在后台异步将脏页回写到磁盘。这种"零 syscall 写入"是 SegmentedLog 高性能的基础。

非 Linux 平台回退到 `file.write(data)`，每次写入都会经过 `write()` 系统调用。

### 轮转机制（rotate）

当 `currentSize + data.size > maxFileSize` 时自动触发，也可手动调用：

```
doRotate()
  ├─ syncImpl()                          // 刷盘当前 segment
  ├─ munmap(mmapPtr, maxFileSize)        // 解除映射（Linux）
  ├─ file.close()                        // 关闭当前文件
  ├─ oldFiles.add(curPath)               // 记录旧路径
  ├─ seq += 1
  ├─ File(newPath, ReadWrite)            // 创建新文件
  ├─ ftruncate + fallocate + mmap        // 映射新文件（Linux）
  └─ currentSize = 0, appendCount = 0
```

`startSeq` 默认从 1 开始，文件名格式为 `{prefix}_{seq}.{ext}`，如 `wal_1.log`、`wal_2.log`。

### 刷盘策略

`syncInterval` 参数控制自动 fsync 的频率：

- **syncInterval <= 0**：每次 `append` 后都执行 `file.flush()`，最大程度保证数据安全
- **syncInterval > 0**：每 N 次 append 执行一次 `file.flush()`。例如 `syncInterval = 10` 表示第 1、11、21...次 append 后刷盘

`syncImpl()` 统一调用 `file.flush()`，在 Linux 下等价于 `msync()` + `fsync()`，将 mmap 脏页写回磁盘。

### 线程安全

SegmentedLog 是线程安全的，通过以下机制实现：

| 场景 | 保护机制 |
|------|----------|
| append + rotate 互斥 | `appendLock`（Mutex）保护整个临界区，包括超限检查、写入、sync |
| oldFiles 并发访问 | `oldFilesLock`（Mutex）保护 `takeOldFiles()` 和 `doRotate()` 中的 add |
| close 与 append 的竞态 | `closed` 标志位用 `AtomicBool` 的 CAS 确保仅首次生效，`synchronized(appendLock)` 等待正在进行的 append 完成 |
| 状态变量的可见性 | `seq`、`currentSize`、`appendCount` 均使用 `AtomicInt64`，`Mutex` 提供 acquire/release 语义 |

### 关闭协议

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

双保险设计：

1. **CAS** `closed` 标志 — 确保 `close()` 只执行一次，后续调用立即返回
2. **synchronized(appendLock)** — 确保没有正在进行的 `append()`，防止 close 与写入并发
3. 在锁内执行最后的 sync + 解除映射 + 关闭文件

### 跨平台条件编译

| 方法 | Linux 行为 | 非 Linux 行为 |
|------|-----------|--------------|
| `initFileMapping` | `ftruncate + fallocate + mmap(MAP_SHARED)` | 返回 `CPointer<Byte>()`（null） |
| `unmapFile` | `munmap(ptr, size)` | 空操作 |
| `writeImpl` | `memcpy(mmapPtr + pos, data)` — 零 syscall | `file.write(data)` |
| `syncImpl` | `file.flush()` — 实际触发 `msync + fsync` | `file.flush()` |

### 与 WAL 的关系

SegmentedLog 最初是为 `f_store::WAL`（Write-Ahead Log）提取的通用层。WAL 的核心约束与 SegmentedLog 的设计完全吻合：

- **顺序追加** — WAL 只追加不修改
- **分段管理** — 固定大小文件便于旧 segment 的 checkpoint 后删除
- **可配置 fsync 频率** — WAL 可在性能与持久性之间权衡
- **崩溃恢复** — `LogPosition` 可作为确认点，记录已写入的 segment 和偏移

### 使用模式

典型生命周期：

```
1. 创建 SegmentedLog
2. 循环 append(data) ← 自动 rotate
3. 定期 checkpoint
4. takeOldFiles() → 删除已 checkpoint 的旧文件
5. close()
```

不提供读取 API，读取由上层模块（如 WAL 的 recovery）自行按文件名规则遍历旧文件执行 `pread`。


固定大小分段、纯顺序追加的写日志。Linux 使用 mmap 零 syscall 写入，非 Linux 回退 file.write()。供 WAL 等模块复用。


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
    // 缓冲区容量
    public prop capacity: Int64 
    
    // 缓冲区写入位置
    public prop writeOffset: Int64 
    // 缓冲区读取位置
    public prop readOffset: Int64 

    // 获取未读字节切片
    public func bytes(): Array<Byte> 
    // 修改writeOffset 和readOffset为0，是否清除数据由toOverwriteOnClearing决定
    public func clear(): Unit 
    public func clone(): ByteBuffer 
    // 扩容，如果capacity - writeOffset + readOffset >= addition，则只将未读数据移到缓冲区头部，而不扩容
    public func reserve(addition: Int64): Unit 
    // 移动缓冲区的读取位置，移动范围从缓冲区头部到writeOffset
    public func seekReading(pos: SeekPosition): Unit 
    // 移动缓冲区的写入位置，移动范围从readOffset到缓冲区尾
    public func seekWriting(pos: SeekPosition): Unit 
    // 读取一字节，如果没有可读字节立即返回None
    public func readByte(): ?Byte
    // 读取字节数组，返回实际读取的字节数，读取字节数小于等于writeOffset - readOffset
    public func read(buf: Array<Byte>): Int64 
    // 写一字节，如果缓冲区已满将自动扩容capacity/2 + buf.size
    public func writeByte(b: Byte): Unit 
    // 写入缓冲区，如果可写空间不足，将自动扩容capacity/2 + buf.size
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
    
    // 缓冲区容量
    public prop capacity: Int64 
    // 缓冲区写入位置
    public prop writeOffset: Int64 
    // 缓冲区读取位置
    public prop readOffset: Int64 
    // 不安全的操作，返回缓冲区全部未读字节切片
    public unsafe func bytes(): Array<Byte> 
    // 只把readOffset和writeOffset改为0，是否清除数据由toOverwriteOnClearing决定
    public func clear(): Unit 
    public func clone(): ByteBuffer 
    // 扩容，如果缓冲区已满将自动扩容addition，如果
    public func reserve(addition: Int64): Unit 
    // 改变缓冲区的读取位置，读取范围从缓冲区头部到writeOffset
    public func seekReading(pos: SeekPosition): Unit 
    // 改变缓冲区的写入位置，写入范围从readOffset到缓冲区尾部
    public func seekWriting(pos: SeekPosition): Unit 
    // 读取一字节，如果没有可读字节立即返回None
    public func readByte(): ?Byte
    // 读取一字节，无可读字节将等待timeout时长，如果timeout==Duration.Zero立即返回None<Byte>
    // 如果超时后尚无可读字节返回None，如果已调用end()函数返回None
    public func readByte(timeout: Duration): ?Byte 
    // 读取的字节数小于等于buf.size，如果没有可读内容将等待timeout时长，如果timeout==Duration.Zero立即返回None<Int64>
    // 如果超时后尚无可读字节返回None，如果已调用end()函数返回0
    public func read(buf: Array<Byte>, timeout: Duration): ?Int64 
    // 如果没有可读内容将立即返回0
    public func read(buf: Array<Byte>): Int64 
    // 写入一字节，如果缓冲区已满将自动扩容capacity/2
    public func writeByte(b: Byte): Unit 
    // 写入字节数组，如果缓冲区已满将自动扩容capacity/2 + buf.size
    public func write(bytes: Array<Byte>): Unit 
    public func flush(): Unit {}
    // 确认不再需要写入字节调用此函数
    public func end(): Unit 
    // 在同步块内调用fn，跟其它函数使用同一个锁实例
    public func batch(fn: (ByteBuffer) -> Unit): Unit
}
```

### 扩展Path
```cj
//复制时会忽略空文件夹
//to 是复制的目标路径，必须是Directory
//如果当前路径是符号连接则递归读取连接的目标文件再复制
//matched 是过滤函数，源路径满足matched的才会复制
//srcPattern是源路径模式，文件路径满足这个模式的才会复制。**表示任意级别的路径，*表示任意零个或多个字符
//对于matched和srcPattern，当前路径如果是Directory，则其下每个文件都会执行这个判断
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