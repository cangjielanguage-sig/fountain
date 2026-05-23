# LSM-Tree 存储引擎技术方案

## 1. 概述

基于 LSM-Tree（Log-Structured Merge-Tree）架构实现键值存储引擎，**以极致性能为第一目标**。

### 核心组件
- **ConcurrentSkipListMap**：内存有序表（MemTable），提供无锁并发读写
- **IOUringStream**：双 ring 架构（写 ring 异步 + 读 ring 同步），提供无锁并发 IO
- **IoUringPool**：多 io_uring 实例轮询，不同用途隔离避免互相阻塞
- **LockFreePromise**：无锁 CQE 等待，避免 Mutex 开销
- **BloomFilter**：SSTable 布隆过滤器，加速点查询

### 设计原则
1. **极致性能**：所有 IO 路径无锁，WAL 写后即返回，MemTable 修改后即返回
2. **原子操作**：add/remove/get 是原子的，add/remove 在写入 WAL 且修改跳表后即可返回
3. **异步无锁 IO**：Linux 下所有磁盘 IO 使用 `IOUringStream`（写 ring 异步提交 + 后台收割），不阻塞调用线程
4. **平台适配**：Linux 使用 io_uring FFI 封装，非 Linux 使用 `std.fs.File` 同步 IO

### 数据流

```
写入 → WAL(IOUringStream异步写) → MemTable(跳表CAS) → [满] → Immutable MemTable → 异步刷盘 → SSTable(L0)
                                                                                              ↓
                                                                Compaction → L1 → L2 → ...
```

### 核心约束
- add/remove/get 原子且无锁并发安全
- add/remove 在 WAL 写入 + MemTable 修改后即可返回，不等 IO 落盘
- prefix 遍历并发安全但不必原子，不影响写操作
- 每个持久化文件 ≤ 64MB，对应一个布隆过滤器
- 删除不修改已持久化文件（靠 tombstone 标记）
- 崩溃后可从 WAL 恢复

---

## 2. 数据结构

### 2.1 ByteArray — 有序字节数组

```cj
public struct ByteArray <: Comparable<ByteArray> {
    public ByteArray(public let bytes: Array<Byte>){}
    public func compare(other: ByteArray): Ordering {
        let minLen = if (bytes.size <= other.bytes.size) { bytes.size } else { other.bytes.size }
        for (i in 0..minLen) {
            match (bytes[i].compare(other.bytes[i])){
                case EQ => continue
                case x => return x
            }
        }
        bytes.size.compare(other.bytes.size)
    }
}
```

**要点**：
- 字节序逐字节比较，短数组为前缀时短的小
- 作为 `ConcurrentSkipListMap<ByteArray, EntryValue>` 的 key，必须实现 `Comparable`
- `Array<Byte>` 是引用类型，struct 包装避免跳表节点间多余的堆分配

### 2.2 EntryValue — 值或删除标记

```cj
public class EntryValue {
    public let value: ?Array<Byte>   // None = tombstone（删除标记）
    public let sequence: Int64       // 单调递增序列号，用于多版本合并
    public let expireAt: ?Int64      // 过期时间戳（纳秒），None = 永不过期
    public init(value: ?Array<Byte>, sequence: Int64, expireAt!: ?Int64 = None) {
        this.value = value
        this.sequence = sequence
        this.expireAt = expireAt
    }
}
```

**要点**：
- `value == None` 表示 tombstone，`get` 遇到 tombstone 返回 `None`
- `sequence` 保证并发写入的全局顺序，读操作优先取高序列号
- `expireAt` 为 `None` 表示永不过期；非 `None` 时为纳秒级时间戳，`get` 时检查是否已过期
- 不可变对象，一旦创建不再修改
- `ttl` 操作通过写入新的 `EntryValue`（相同 value + 新 expireAt）实现过期时间更新

---

## 3. IO 抽象层 — 平台适配

### 3.1 设计思路

所有 IO 操作通过抽象层隔离平台差异：
- **Linux**：直接使用 `fountain::f_io.IOUringStream`（双 ring 架构：写 ring 异步 + 读 ring 同步）
- **非 Linux**：使用 `std.fs.File` 同步 IO

`IOUringStream` 已实现 `std.io.IOStream & Resource`，提供 `write`/`read`/`flush`/`close`/`isClosed`，无需再定义独立的 IO 抽象层。

```cj
// Linux 下直接使用 IOUringStream（已实现 IOStream & Resource）
// 非 Linux 下使用 std.fs.File（已实现 IOStream & Seekable & Resource）
//
// 类型统一为 IOStream，无需自定义 StoreIOStream 接口
```

### 3.2 Linux 实现 — 直接使用 IOUringStream

`fountain::f_io.IOUringStream` 已实现 `IOStream & Resource`，双 ring 架构完全覆盖 f_store 的 IO 需求：

| IOUringStream 能力 | f_store 用途 |
|-------------------|-------------|
| `write()` — 异步提交写 SQE，后台收割线程处理 CQE | WAL 追加、SSTable 刷盘、Compaction 写入 |
| `read()` — 同步 submit + waitCQE | SSTable 点查询 |
| `flush()` — `IOSQE_IO_DRAIN` + fsync + `LockFreePromise` 等待 | WAL 定期 fsync、SSTable 写完 fsync |
| `close()` — 停止收割线程 + 关闭双 ring | 关闭 WAL/SSTable 文件 |
| Registered Buffers — 可选零拷贝模式 | 后续性能优化 |

**WAL 创建示例**：
```cj
@When[os == "Linux"]
class WAL <: Resource {
    let file: File                   // 保持 File 存活（fd 依赖它）
    let stream: IOUringStream        // 直接使用 IOUringStream
    // ...

    init(path: String, mode: OpenMode, entries!: UInt32 = 64) {
        file = File(path, mode)
        stream = IOUringStream(file.fd, entries)
    }
}
```

**无需自定义 IOUringStoreIOStream 的原因**：
- `IOUringStream` 双 ring 架构（写 ring 异步 + 读 ring 同步）天然匹配 LSM-Tree 读写模式
- `flush()` 使用 `IOSQE_IO_DRAIN` 保证所有先前写完成后再 fsync，语义正确
- 支持 Registered Buffers，为后续优化预留能力
- 避免重复实现 io_uring 生命周期管理（收割线程启停、ring 关闭等）

### 3.3 非 Linux 实现 — std.fs.File

`std.fs.File` 已实现 `IOStream & Seekable & Resource`，直接使用即可：

```cj
// 非 Linux 下无需封装，直接用 File（已实现 IOStream）
// 类型统一为 IOStream
```

### 3.4 工厂函数

```cj
func createStoreStream(path: String, mode: OpenMode, entries!: UInt32 = 64): IOStream {
    // @When[os == "Linux"] → IOUringStream(File(path, mode).fd, entries)
    // @When[os != "Linux"] → File(path, mode)  // File 本身就是 IOStream
}
```

**要点**：
- 返回类型统一为 `IOStream`（`IOUringStream` 和 `File` 都实现了 `IOStream`）
- Linux 下 `IOUringStream` 持有 fd 引用，需保持 `File` 对象存活（fd 依赖它）
- 非 Linux 下 `File` 本身就是 `IOStream`，无需任何封装
- `flush()` 语义：Linux 下 `IOUringStream.flush()` 执行 fsync；非 Linux 下 `File.flush()` 为 no-op

### 3.5 io_uring 实例分配（Linux）

| 用途 | IOUringStream 实例 | 写 ring 模式 | 读 ring 模式 | 说明 |
|------|-------------------|-------------|-------------|------|
| WAL 写入 | 专属 | 异步提交 + 后台收割 | 同步 submit + waitCQE | append 后立即返回，定期 flush() |
| SSTable 刷盘 | 专属 | 异步提交 + 后台收割 | — | 异步写入 Data Block |
| SSTable 读取 | 专属 | — | 同步 submit + waitCQE | get/prefix 时按需读取 |
| Compaction | 专属 | 异步提交 + 后台收割 | 同步 submit + waitCQE | 合并读写新 SSTable |

**要点**：
- 每个 IO 目的（WAL、SSTable写、SSTable读、Compaction）使用独立 `IOUringStream` 实例（独立双 ring），避免 SQ 争用
- 写路径通过 `IOUringStream.write()` 异步提交，后台收割线程处理 CQE，`write()` 返回后不阻塞
- 读路径通过 `IOUringStream.read()` 同步等待（读 ring 的 submit + waitCQE），天然适合点查询
- `flush()` 执行 `IOSQE_IO_DRAIN` + fsync，保证所有先前写完成后再 fsync
- 非 Linux 全部降级为 `std.fs.File` 同步 IO

---

## 4. 核心组件

### 4.1 MemTable — 内存表

```cj
class MemTable {
    let table: ConcurrentSkipListMap<ByteArray, EntryValue>
    let byteCount: AtomicInt64   // 近似内存占用

    init() {
        table = ConcurrentSkipListMap<ByteArray, EntryValue>()
        byteCount = AtomicInt64(0)
    }

    func add(key: ByteArray, entry: EntryValue): ?EntryValue {
        let old = table.add(key, entry)
        byteCount.fetchAdd(key.bytes.size + (entry.value?.size ?? 0) + 24)
        old
    }

    func get(key: ByteArray): ?EntryValue {
        table.get(key)
    }

    func iterator(): Iterator<(ByteArray, EntryValue)> {
        table.iterator()
    }

    func tailer(min: ByteArray): Iterator<(ByteArray, EntryValue)> {
        table.tailer(min, including: true)
    }

    func approximateSize(): Int64 {
        byteCount.load()
    }
}
```

**要点**：
- 直接委托 `ConcurrentSkipListMap`，其本身无锁并发安全
- `byteCount` 是近似值，用于判断是否需要刷盘，弱一致性可接受
- `add` 返回旧值，用于 `Store.add` 的返回值语义

### 4.2 双缓冲 MemTable 管理

```
┌─────────────┐     满/手动flush     ┌──────────────────┐
│  MemTable   │ ──────────────────→  │ Immutable MemTable│ ──→ 异步刷盘
│  (active)   │                      │   (只读快照)      │
└─────────────┘                      └──────────────────┘
```

```cj
class MemTableManager {
    let active: AtomicReference<MemTable>
    let immutable: AtomicReference<?MemTable>
    let flushLock: Mutex   // 仅用于 swap 时的互斥，不影响读写

    func swapActive(): ?MemTable {
        // 1. 获取 flushLock
        // 2. 取当前 active 作为 immutable
        // 3. 创建新的 active
        // 4. 释放 flushLock
        // 返回旧的 active（现 immutable）
    }
}
```

**要点**：
- `active` 始终可读写，swap 操作用 `AtomicReference` 交换，读操作无锁
- `flushLock` 仅保护 swap 过程（几微秒），不阻塞并发 add/remove/get
- swap 后，immutable 是只读快照，**异步刷盘**（不阻塞写线程）
- 如果 immutable 尚未刷完而 active 又满了，需阻塞等待（背压）

**并发安全分析**：
- add/remove/get 操作只读 `active`，走 `ConcurrentSkipListMap` 的无锁路径
- swap 时 `AtomicReference` 提供原子切换，新写入自动路由到新 active
- immutable 只读，不存在并发修改问题

### 4.3 WAL — 预写日志

#### 格式设计

每个 WAL 记录：
```
┌──────────┬──────────┬──────────┬─────────────┬────────────┬──────────┬────────────┬────────────┐
│ checksum │ sequence │ key_len  │ value_len   │ expire_at  │ key_bytes │ value_bytes│
│ 4 bytes  │ 8 bytes  │ 8 bytes  │ 8 bytes     │ 8 bytes    │ var       │ var        │
│ CRC32    │ Int64    │ Int64    │ Int64       │ Int64      │           │ -1=删除    │
└──────────┴──────────┴──────────┴─────────────┴────────────┴────────────┴────────────┘
```

- `value_len < 0` 表示 tombstone（删除记录）；`value_len >= 0` 为正常 value（含空数组）
- `expire_at = 0` 表示永不过期，非零为纳秒级过期时间戳
- `checksum` 覆盖 sequence + key_len + value_len + expire_at + key_bytes + value_bytes

#### 实现架构（Linux）

```cj
@When[os == "Linux"]
class WAL <: Resource {
    let file: File                       // 保持 File 存活（fd 依赖它）
    let stream: IOUringStream            // 双 ring：写 ring 异步 + 读 ring 同步
    let sequence: AtomicInt64            // 当前序列号
    let appendCount: AtomicInt64         // 追加计数（用于定期 fsync）
    let closed: AtomicBool
    let syncInterval: Int64              // 每 N 次 append 执行一次 flush（默认 100）

    init(path: String, mode: OpenMode, entries!: UInt32 = 64) {
        file = File(path, mode)
        stream = IOUringStream(file.fd, entries)
    }

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        // 1. sequence.incrFetch() 获取序列号
        // 2. 编码记录（checksum + sequence + key_len + value_len + expire_at + key + value）
        // 3. stream.write(encoded) — 异步提交写 SQE，立即返回
        // 4. appendCount.incrFetch()
        // 5. if (appendCount % syncInterval == 0) { sync() }
        // 返回序列号
        // ★ 关键：write SQE 提交后立即返回，不等待 IO 完成
    }

    func sync(): Unit {
        stream.flush()  // IOSQE_IO_DRAIN + fsync，等所有先前写完成
    }

    func close(): Unit {
        stream.close()  // 停止收割线程 + 关闭双 ring
        file.close()
    }
}
```

#### 实现架构（非 Linux）

```cj
@When[os != "Linux"]
class WAL <: Resource {
    let file: File                 // std.fs.File 同步 IO
    let sequence: AtomicInt64
    let appendCount: AtomicInt64
    let closed: AtomicBool
    let syncInterval: Int64

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        // 1. sequence.incrFetch() 获取序列号
        // 2. 编码记录
        // 3. file.write(encoded) — 同步写
        // 4. 定期 file.flush() 替代 fsync
        // 返回序列号
    }

    func sync(): Unit { file.flush() }
    func close(): Unit { file.close() }
}
```

**要点**：
- **Linux**：WAL 写入通过 `IOUringStream.write()` 异步提交，`append` 提交 SQE 后立即返回，不等 IO 完成
- **非 Linux**：使用 `std.fs.File` 同步写入，`append` 等写完成后返回
- WAL 追加顺序性：`IOUringStream` 内部 `writeMutex` 保证 SQE 提交顺序，无需额外锁
- **★ 无需自定义 writeLock**：`IOUringStream.write()` 内部通过 `writeMutex` 保证写入顺序，WAL 的 `append` 直接调用即可

**崩溃恢复**：
- 启动时读取 WAL 文件，按 sequence 排序重放到 MemTable
- 遇到损坏的 checksum 记录，截断该点之后的数据（WAL 末尾可能不完整）
- 重放完成后删除旧 WAL，创建新 WAL

#### WAL 文件管理

- 文件命名：`{path}/wal/{sequence_start}.wal`
- 刷盘完成后旧 WAL 可删除
- 多个 WAL 文件按序列号范围顺序存在

### 4.4 SSTable — 有序字符串表

#### 文件格式

```
┌─────────────────────────────────────────────────────────────────┐
│ Data Block 1                                                    │
│   key_len(8) + value_len(8) + sequence(8) + expire_at(8) + key + value/tomb   │
│ Data Block 2                                                    │
│   ...                                                           │
│ Data Block N                                                    │
├─────────────────────────────────────────────────────────────────┤
│ Index Block                                                     │
│   [offset(8) + key_len(8) + first_key] * N                     │
│   每个Data Block的首条记录的偏移量和最小key                        │
├─────────────────────────────────────────────────────────────────┤
│ Bloom Filter Block                                              │
│   n(8) + p(8float) + k(8) + seeds(k*8) + bitset_bytes(8)       │
│   + bitset_data                                                 │
├─────────────────────────────────────────────────────────────────┤
│ Footer (固定 48 bytes)                                          │
│   index_offset(8) + index_size(8)                               │
│   bloom_offset(8) + bloom_size(8)                               │
│   entry_count(8) + min_key_len(8) + min_key + padding          │
│   magic_number(8) = 0x53545354 ("STST")                         │
└─────────────────────────────────────────────────────────────────┘
```

**要点**：
- Data Block 存储有序的 key-value 对，按 key 排序（来自跳表的天然有序性）
- Index Block 存储每个 Data Block 的起始偏移和最小 key，用于二分查找
- Bloom Filter Block 存储完整布隆过滤器参数和位集，用于快速排除不存在的 key
- Footer 固定长度，放在文件末尾，读取时先读 Footer 定位其他块

#### SSTable 文件管理

```cj
class SSTableFile <: Resource {
    let path: String
    let stream: IOStream           // Linux: IOUringStream，非 Linux: File
    let metadata: SSTableMetadata // minKey, maxKey, entryCount, level
    let bloomFilter: BloomFilter
    let indexBlock: IndexBlock
}
```

- 文件命名：`{path}/sst/L{level}_{sequence_start}_{sequence_end}.sst`
- 每个文件 ≤ 64MB，达到阈值时关闭当前文件创建新文件
- 文件创建后不可变（不修改已持久化文件）

### 4.5 SSTable 写入流程

```
Immutable MemTable → 编码记录 → IOUringStream 异步批量写入 → flush() → 创建 BloomFilter → 写 Footer → 关闭文件
```

```cj
class SSTableWriter {
    let stream: IOStream        // Linux: IOUringStream，非 Linux: File
    let bloomFilter: BloomFilter
    let indexEntries: ArrayList<IndexEntry>
    var currentOffset: Int64
    var entryCount: Int64
    var fileSize: Int64    // 不超过 64MB

    func write(key: ByteArray, entry: EntryValue): Unit {
        // 1. 编码 key_len + value_len + sequence + key + value/tomb
        // 2. 记录 Index Entry（如果新 Data Block）
        // 3. bloomFilter.add(key.bytes)
        // 4. stream.write(encoded) — Linux: IOUringStream 异步写，非 Linux: File 同步写
        // 5. currentOffset += encoded.size
        // 6. entryCount++
        // 7. fileSize += encoded.size
    }

    func finish(): SSTableMetadata {
        // 1. 写 Index Block
        // 2. 写 Bloom Filter Block
        // 3. 写 Footer
        // 4. stream.sync() — fsync
        // 返回元数据
    }

    func isFull(): Bool {
        fileSize >= MAX_SSTABLE_SIZE  // 64MB
    }
}
```

**要点**：
- Linux 下 `stream.write` 通过 `IOUringStream` 异步提交（写 ring），立即返回不阻塞
- 非 Linux 下 `stream.write` 是同步写，完成后再返回
- `finish` 时调用 `sync()` 确保数据落盘
- 单文件超过 64MB 时停止写入，创建新文件

### 4.6 SSTable 读取

```cj
class SSTableReader {
    let metadata: SSTableMetadata
    let bloomFilter: BloomFilter
    let indexBlock: IndexBlock
    let stream: IOStream     // Linux: IOUringStream，非 Linux: File

    func get(key: ByteArray): ?EntryValue {
        // 1. bloomFilter.mightContain(key.bytes) → false 则直接返回 None
        // 2. 二分查找 Index Block 定位 Data Block
        // 3. stream.read(buffer) 读取 Data Block
        //    Linux: IOUringStream 同步读路径（读 ring 的 submit + waitCQE）
        //    非 Linux: File.read 同步读
        // 4. 在 Data Block 内线性/二分查找 key
        // 返回 EntryValue 或 None
    }
}
```

**要点**：
- BloomFilter 快速排除不存在 key 的 SSTable，避免不必要的磁盘 I/O
- Index Block 二分定位 Data Block，减少读取范围
- Linux 下读取使用 `IoUring` 的同步读路径（submit + waitCQE），天然适合点查询
- 非 Linux 下使用 `File.read` 同步读

### 4.7 Level 管理

```
Level 0: 直接从 Immutable MemTable 刷出，key 范围可重叠
Level 1+: 同层 key 范围不重叠，有序排列
```

```cj
class LevelManager {
    let levels: Array<ArrayList<SSTableFile>>   // levels[0] = L0, levels[1] = L1, ...
    let levelLocks: Array<Mutex>                 // 每层一个锁，仅保护结构变更

    // L0 触发条件：L0 SSTable 数量 ≥ 4
    // Ln 触发条件：Ln 总大小 ≥ 10^n MB（L1=10MB, L2=100MB, L3=1GB...）
}
```

**要点**：
- L0 允许范围重叠，查询时需检查所有 L0 SSTable
- L1+ 范围不重叠，查询时二分定位目标 SSTable
- Compaction 后的 SSTable 保证范围不重叠

---

## 5. Store 主类实现

### 5.1 类定义

```cj
public class Store <: Resource {
    private let path: Path
    private let memTableManager: MemTableManager
    private let wal: WAL
    private let levelManager: LevelManager
    private let sequence: AtomicInt64        // 全局单调递增序列号
    private let closed: AtomicBool
    private let memFlushThreshold: Int64     // MemTable 刷盘阈值（字节）
}
```

### 5.2 初始化

```cj
public init(path: String) {
    this(Path(path))
}

public Store(private let path: Path) {
    // 1. 创建目录结构（如果不存在）
    //    path/wal/
    //    path/sst/
    // 2. 恢复 WAL → 重建 MemTable
    // 3. 加载 SSTable 元数据（Footer + BloomFilter + IndexBlock）
    // 4. 创建新 WAL 文件（Linux: IOUringStream，非 Linux: File）
    // 5. 启动 Compaction 后台线程
    // 6. atExit(this.close)
}
```

**目录结构**：
```
{path}/
├── wal/
│   └── 0000000000000001.wal
└── sst/
    ├── L0_0000000000000001_0000000000001000.sst
    └── L1_0000000000000001_0000000000005000.sst
```

### 5.3 add — 添加键值对

```cj
public func add(key: Array<Byte>, value: Array<Byte>): ?Array<Byte> {
    if (closed.load()) { throw StoreClosedException() }
    let keyBytes = ByteArray(key)
    // 1. WAL 追加记录，获取序列号
    let seq = wal.append(key, value)
    // 2. 写入 MemTable
    let entry = EntryValue(value, seq)
    let old = memTableManager.active.load().add(keyBytes, entry)
    // 3. 检查是否需要刷盘
    maybeFlush()
    // 4. 返回旧值（如果 key 已存在）
    old?.value
}
```

**原子性保证**：
- `wal.append` 提交 SQE 后立即返回（Linux），记录已进入 io_uring 写队列
- `ConcurrentSkipListMap.add` 是原子操作（CAS）
- 写入顺序：WAL 先于 MemTable（WAL 成功后才写入 MemTable）
- ★ **add 在 WAL 写入 + MemTable 修改后即可返回**，不等 IO 落盘完成

**并发安全**：
- `IOUringStream.write()` 内部 `writeMutex` 保护 SQE 提交顺序，WAL `append` 直接调用即可
- `ConcurrentSkipListMap.add` 无锁 CAS
- `maybeFlush` 检查是近似判断，多线程可能同时触发但 swap 有 flushLock 保护

```cj
public func add(key: Array<Byte>, value: Array<Byte>, expire: Duration): ?Array<Byte> {
    if (closed.load()) { throw StoreClosedException() }
    let keyBytes = ByteArray(key)
    let expireAt = DateTime.now().toUnixTimestamp() + expire.toNanoseconds()
    // 1. WAL 追加记录，获取序列号
    let seq = wal.append(key, value, expireAt: expireAt)
    // 2. 写入 MemTable
    let entry = EntryValue(value, seq, expireAt: expireAt)
    let old = memTableManager.active.load().add(keyBytes, entry)
    // 3. 检查是否需要刷盘
    maybeFlush()
    // 4. 返回旧值（如果 key 已存在且未过期）
    if (let Some(oldEntry) <- old) {
        if (let Some(oldExpire) <- oldEntry.expireAt) {
            if (oldExpire <= DateTime.now().toUnixTimestamp()) {
                return None  // 旧值已过期，视为不存在
            }
        }
        oldEntry.value
    } else {
        None
    }
}
```

**原子性保证**：
- 与 `add(key, value)` 一致：WAL 先写 + MemTable CAS
- 过期时间与 value 一同写入，保证原子性
- ★ **add 在 WAL 写入 + MemTable 修改后即可返回**，不等 IO 落盘完成

**并发安全**：
- 与 `add(key, value)` 一致，关键路径完全无锁

### 5.5 ttl — 设置/更新过期时间

```cj
public func ttl(key: Array<Byte>, expire: Duration): Unit {
    if (closed.load()) { throw StoreClosedException() }
    let keyBytes = ByteArray(key)
    let expireAt = DateTime.now().toUnixTimestamp() + expire.toNanoseconds()
    // 1. 查找当前值
    let current = memTableManager.active.load().get(keyBytes)
    // 也查 immutable
    if (current.isNone()) {
        if (let Some(imm) <- memTableManager.immutable.load()) {
            let immEntry = imm.get(keyBytes)
            if (let Some(e) <- immEntry) {
                // 找到值，用其 value + 新 expireAt 重新写入
                let seq = wal.append(key, e.value ?? Array<Byte>(), expireAt: expireAt)
                let entry = EntryValue(e.value, seq, expireAt: expireAt)
                memTableManager.active.load().add(keyBytes, entry)
                return
            }
        }
        // 也查 SSTable
        let sstEntry = levelManager.get(keyBytes)
        if (let Some(e) <- sstEntry) {
            if (e.value.isSome()) {
                let seq = wal.append(key, e.value ?? Array<Byte>(), expireAt: expireAt)
                let entry = EntryValue(e.value, seq, expireAt: expireAt)
                memTableManager.active.load().add(keyBytes, entry)
                return
            }
        }
        // key 不存在，ttl 无操作
        return
    }
    // 2. 在 active MemTable 中找到值，用其 value + 新 expireAt 重新写入
    if (let Some(e) <- current) {
        if (e.value.isSome()) {
            let seq = wal.append(key, e.value ?? Array<Byte>(), expireAt: expireAt)
            let entry = EntryValue(e.value, seq, expireAt: expireAt)
            memTableManager.active.load().add(keyBytes, entry)
        }
        // tombstone 或已过期，ttl 无操作
    }
}
```

**要点**：
- `ttl` 查找 key 的当前值，以相同 value + 新 expireAt 重新写入
- 新 EntryValue 的 sequence 高于旧值，查询时优先返回带过期时间的新版本
- ★ **ttl 在 WAL 写入 + MemTable 修改后即可返回**
- key 不存在或已删除（tombstone）时，`ttl` 为空操作
- **并发安全**：与 add 一致，关键路径无锁。极端情况下并发 add 可能覆盖 ttl 写入的值，但符合 LSM 语义（后写入者胜）

### 5.6 remove — 删除键

```cj
public func remove(key: Array<Byte>): ?Array<Byte> {
    if (closed.load()) { throw StoreClosedException() }
    let keyBytes = ByteArray(key)
    // 1. WAL 追加 tombstone 记录
    let seq = wal.append(key, None)  // value = None 表示删除
    // 2. 写入 MemTable（tombstone）
    let entry = EntryValue(None, seq)
    let old = memTableManager.active.load().add(keyBytes, entry)
    // 3. 返回被删除的值
    old?.value
}
```

**要点**：
- 删除是特殊的写入——写入 tombstone 而非物理删除
- tombstone 的 sequence 高于旧值，查询时会优先返回"已删除"
- 已持久化 SSTable 中的旧记录不会被修改，compaction 时清理
- ★ **remove 在 WAL 写入 + MemTable 修改后即可返回**

### 5.7 get — 查询键

```cj
public func get(key: Array<Byte>): ?Array<Byte> {
    if (closed.load()) { throw StoreClosedException() }
    let keyBytes = ByteArray(key)

    // 1. 查 active MemTable
    let active = memTableManager.active.load()
    if (let Some(entry) <- active.get(keyBytes)) {
        // 检查是否过期
        if (let Some(expireAt) <- entry.expireAt) {
            if (expireAt <= DateTime.now().toUnixTimestamp()) {
                return None  // 已过期，视为不存在
            }
        }
        return entry.value  // None = tombstone，返回 None 表示 key 不存在
    }

    // 2. 查 immutable MemTable（可能正在刷盘）
    if (let Some(imm) <- memTableManager.immutable.load()) {
        if (let Some(entry) <- imm.get(keyBytes)) {
            if (let Some(expireAt) <- entry.expireAt) {
                if (expireAt <= DateTime.now().toUnixTimestamp()) {
                    return None
                }
            }
            return entry.value
        }
    }

    // 3. 查 SSTable（从 L0 到 Ln，找到第一个即返回）
    let result = levelManager.get(keyBytes)
    if (let Some(entry) <- result) {
        if (let Some(expireAt) <- entry.expireAt) {
            if (expireAt <= DateTime.now().toUnixTimestamp()) {
                return None
            }
        }
        return entry.value
    }
    None
}
```

**查询优先级**：active MemTable > immutable MemTable > L0 SSTable > L1 SSTable > ...

**要点**：
- 找到 tombstone（`entry.value == None`）立即返回 `None`，不需要继续查找更底层
- 找到过期数据（`entry.expireAt <= now`）立即返回 `None`，视为不存在
- `ConcurrentSkipListMap.get` 无锁，不影响并发写
- SSTable 查询利用 BloomFilter 快速排除

### 5.8 prefix — 前缀遍历

```cj
public func prefix(prefix: Array<Byte>): Iterator<(Array<Byte>, Array<Byte>)> {
    let prefixBytes = ByteArray(prefix)

    // 合并多个有序源的迭代器
    // 1. active MemTable.tailer(prefixBytes) — 从 prefix 开始遍历
    // 2. immutable MemTable.tailer(prefixBytes) — 如果存在
    // 3. L0 SSTable 中范围匹配的文件（需检查所有 L0 SSTable）
    // 4. Ln SSTable 中范围匹配的文件

    // 返回合并迭代器，按 sequence 去重（高序列号优先）
    PrefixIterator(prefixBytes, sources)
}
```

**PrefixIterator 实现要点**：
```cj
class PrefixIterator <: Iterator<(Array<Byte>, Array<Byte>)> {
    let prefix: ByteArray
    let heap: MinHeap<PeekableIterator>  // 按 key 排序的最小堆

    func next(): ?(Array<Byte>, Array<Byte>) {
        // 1. 从堆顶取最小 key
        // 2. 如果 key 不以 prefix 开头，结束迭代
        // 3. 合并相同 key 的多个版本，取最高 sequence
        // 4. 如果是 tombstone，跳过；如果已过期，跳过；否则返回 (key, value)
        // 5. 推进对应迭代器，重新入堆
    }
}
```

**并发安全**：
- `ConcurrentSkipListMap.tailer` 返回弱一致性迭代器，遍历期间不阻塞写操作
- SSTable 文件创建后不可变，读取无并发问题
- 可能看到部分写入（弱一致性），但不会导致数据损坏

**性能**：
- `tailer(min)` 利用跳表索引，O(log n) 定位起始位置
- 前缀遍历只需扫描 `[prefix, prefix+1)` 范围内的数据

### 5.9 close — 关闭存储

```cj
public func close(): Unit {
    if (!closed.compareAndSwap(false, true)) {
        return  // 已关闭
    }

    // 1. 停止 Compactor
    compactor.stop()

    // 2. flush 已有的 immutable MemTable（如果有）
    if (let Some(imm) <- memTableManager.getImmutable()) {
        flushMemTable(imm, sstDir, 0)
        memTableManager.clearImmutable()
    }

    // 3. swapActive → 将当前 active 原子切换为 immutable，再 flush
    if (let Some(imm) <- memTableManager.swapActive()) {
        flushMemTable(imm, sstDir, 0)
        memTableManager.clearImmutable()
    }

    // 4. WAL sync + close
    wal.sync()
    wal.close()

    // 5. 关闭所有 SSTable 文件
    levelManager.closeAll()
}
```

---

## 6. Compaction — 压实合并

### 6.1 触发条件

| Level | 触发条件 | 合并策略 |
|-------|---------|---------|
| L0 | SSTable 数量 ≥ 4 | L0 → L1（必须合并，因 L0 范围重叠） |
| L1 | 总大小 ≥ 10MB | L1 → L2 |
| L2 | 总大小 ≥ 100MB | L2 → L3 |
| Ln | 总大小 ≥ 10^n MB | Ln → Ln+1 |

### 6.2 Compaction 流程

```
1. 选择输入 SSTable（本层 + 下一层有范围重叠的 SSTable）
2. 多路归并排序（按 key 合并，高 sequence 优先）
3. 过滤 tombstone 和已过期数据（被删除或已过期的 key 不写入新 SSTable）
4. 写入新的 SSTable 文件（通过 IOUringStream 异步写，或 File 同步写）
5. 原子替换：删除旧 SSTable，添加新 SSTable
```

```cj
class Compactor {
    let levelManager: LevelManager
    let stream: IOStream           // 专用于 compaction 的 IO 流（Linux: IOUringStream，非 Linux: File）

    func compact(level: Int64): Unit {
        // 1. 选择输入 SSTable
        let inputs = selectInputs(level)

        // 2. 多路归并
        let merger = SSTableMerger(inputs)

        // 3. 写入新 SSTable
        let writer = SSTableWriter(newFilePath, estimatedCount)
        while (let Some((key, entry)) <- merger.next()) {
            if (entry.value.isSome() && !isExpired(entry)) {  // 跳过 tombstone 和已过期
                writer.write(key, entry)
            }
        }
        let metadata = writer.finish()

        // 4. 原子替换
        levelManager.replace(level, inputs, metadata)
    }
}
```

**要点**：
- Compaction 在后台线程执行，不阻塞读写
- 合并时跳过 tombstone 和已过期数据（除非该 key 可能在更底层存在，保守策略是只移除确定可清理的 tombstone；已过期数据可直接丢弃）
- 新 SSTable 写完后再删除旧的，保证崩溃恢复后数据完整
- Linux 下使用专属 `IOUringStream` 避免与 WAL/刷盘争抢 io_uring 资源
- 非 Linux 下使用 `std.fs.File` 同步写入

### 6.3 并发安全

- Compaction 期间，旧 SSTable 仍可被查询
- 新 SSTable 写完后，原子更新 LevelManager 中的引用
- 旧 SSTable 引用计数归零后延迟删除（避免正在读取的迭代器失效）

---

## 7. 崩溃恢复

### 7.1 恢复流程

```
启动 → 1. 扫描 SSTable 文件 → 加载元数据
      → 2. 扫描 WAL 文件 → 按 sequence 重放到 MemTable
      → 3. 截断损坏的 WAL 记录（checksum 校验失败处）
      → 4. 删除旧 WAL，创建新 WAL
      → 5. 就绪
```

### 7.2 WAL 记录读取

```cj
func recoverWAL(path: Path): MemTable {
    let table = MemTable()
    let walFiles = listWALFiles(path)  // 按序列号排序

    for (walFile in walFiles) {
        try {
            // 逐条读取 WAL 记录（使用 std.fs.File 同步读，恢复是启动时一次性操作）
            while (let Some(record) <- readNextRecord(walFile)) {
                if (verifyChecksum(record)) {
                    let entry = EntryValue(record.value, record.sequence, expireAt: record.expireAt)
                    table.add(ByteArray(record.key), entry)
                } else {
                    break  // checksum 失败，截断后续记录
                }
            }
        }
    }
    table
}
```

**要点**：
- WAL 恢复使用 `std.fs.File` 同步读（启动时一次性操作，无需 io_uring）
- WAL 记录按 sequence 排序，后写入的覆盖先写入的（符合 LSM 语义）
- checksum 失败说明进程在写入过程中崩溃，截断该记录及之后所有记录
- io_uring 异步写入的记录可能未落盘——但 WAL 每次 append 后定期 fsync，最坏丢失最后一次 fsync 之后的数据

### 7.3 fsync 策略

- **每次 WAL append 后不立即 fsync**（性能代价太高）
- **定期 fsync**：每 N 次 append 或每 T 毫秒 fsync 一次
- 可配置 `syncMode`：
  - `ASYNC`：不主动 fsync（依赖内核回写，最高性能，崩溃可能丢数据）
  - `PERIODIC`：定期 fsync（平衡性能和持久性，默认）
  - `SYNC`：每次 append 后 fsync（最高持久性，性能最低）

---

## 8. 并发安全总结

### 8.1 操作并发矩阵

| 操作 | add | add(expire) | ttl | remove | get | prefix | compaction |
|------|-----|-------------|-----|--------|-----|--------|------------|
| add | ✅无锁 | ✅无锁 | ✅无锁 | ✅无锁 | ✅无锁 | ✅无锁 | ✅ |
| add(expire) | | ✅无锁 | ✅无锁 | ✅无锁 | ✅无锁 | ✅无锁 | ✅ |
| ttl | | | ✅无锁 | ✅无锁 | ✅无锁 | ✅无锁 | ✅ |
| remove | | | | ✅无锁 | ✅无锁 | ✅无锁 | ✅ |
| get | | | | | ✅无锁 | ✅无锁 | ✅ |
| prefix | | | | | | ✅无锁 | ✅ |
| compaction | | | | | | | 🔒后台 |

### 8.2 锁使用

| 锁 | 保护对象 | 持有时间 | 说明 |
|----|---------|---------|------|
| MemTableManager.flushLock | MemTable swap | 微秒级（引用交换） | 不阻塞读写 |
| LevelManager.levelLocks[n] | SSTable 列表变更 | 毫秒级（Compaction替换） | 不阻塞查询 |
| IoUringStream writeMutex | SQE 提交顺序 | 微秒级（getSQE + flush） | 不阻塞业务逻辑 |

**★ add/remove/get/ttl 的关键路径完全无锁**：
- `ConcurrentSkipListMap` 提供无锁读写
- `IOUringStream` 的 `writeMutex` 仅保护 SQE 提交顺序（微秒级），不阻塞业务逻辑
- WAL `append` 调用 `stream.write()` 后立即返回

### 8.3 原子性保证

- **add**：WAL append（SQE 提交） + MemTable add（CAS），WAL 先写保证崩溃可恢复
- **add(expire)**：同 add，expireAt 与 value 原子写入
- **ttl**：查找当前值 + WAL append + MemTable add，保证过期时间更新原子性
- **remove**：同 add，写入 tombstone
- **get**：单次跳表查找 + 过期检查 + SSTable 查找，天然原子

---

## 9. 实现要点与注意事项

### 9.1 关键实现要点

1. **序列号是核心**：所有操作依赖全局单调递增序列号决定数据新旧，`AtomicInt64` 分配
2. **WAL 先于 MemTable**：保证崩溃恢复时 WAL 包含所有已确认写入
3. **tombstone 不可丢弃**：除非 Compaction 确认更底层无此 key，否则保留 tombstone
4. **过期检查在 get 时惰性执行**：不主动清理过期数据，get/prefix 遇到过期数据视为不存在，Compaction 时清理已过期记录
5. **SSTable 不可变**：一旦创建不再修改，删除靠 tombstone，物理删除靠 Compaction
6. **64MB 文件上限**：SSTableWriter 跟踪写入大小，达到 64MB 关闭当前文件
7. **prefix 遍历范围**：利用 `tailer(minKey)` 定位起始点，遍历到 key 不以 prefix 开头为止
8. **IOUringStream 双 ring 架构**：WAL 写入、SSTable 刷盘、Compaction 写入使用 `IOUringStream`（写 ring 异步 + 读 ring 同步），无需自定义 IO 封装
9. **平台适配**：Linux 用 `IOUringStream`，非 Linux 用 `std.fs.File`，统一为 `IOStream` 接口

### 9.2 潜在问题与对策

| 问题 | 对策 |
|------|------|
| 过期数据占用存储空间 | 惰性过期 + Compaction 清理，过期数据在 Compaction 时丢弃 |
| io_uring 异步写未落盘时崩溃 | WAL 定期 fsync，可配置同步策略 |
| ConcurrentSkipListMap 弱一致 size | byteCount 是近似值，不影响正确性 |
| L0 SSTable 范围重叠，查询慢 | L0 数量阈值触发 Compaction |
| BloomFilter 无法序列化 bitSet | 临时方案：启动时重建；长期：扩展 f_bloom |
| 多线程同时触发 flush | flushLock 保证只有一个线程执行 swap |
| Compaction 期间查询旧 SSTable | 引用计数或延迟删除，保证读取完整性 |
| fd 在 File 关闭后失效 | WAL/SSTable 生命周期内保持 File 对象存活（IOUringStream 构造需 fd） |
| WAL 写入 io_uring 返回错误 | 抛出异常，不写入 MemTable，上层可重试 |
| ByteArray 的 Array<Byte> 比较性能 | 逐字节比较，可考虑缓存 hashCode |
| IOUringStream writeMutex 争用 | writeMutex 仅保护 SQE 提交顺序（微秒级），争用极低；极端场景可调大 entries |
| 非 Linux 平台同步 IO 性能差 | 架构允许，极致性能目标仅针对 Linux |

### 9.3 仓颉语言特殊注意

1. **lambda 不可捕获可变变量**：Compaction 状态机使用自定义类而非闭包
2. **函数参数不可变**：`add(key: Array<Byte>, value: Array<Byte>)` 中 key/value 不可重新赋值
3. **try-with-resource 要求 Resource 接口**：Store、WAL、SSTableFile 需实现 `Resource`
4. **File 对象关闭后 fd 失效**：IOUringStream 使用 fd 期间保持 File 存活
5. **条件编译**：IOUringStream 相关代码需 `@When[os == "Linux"]`，非 Linux 代码需 `@When[os != "Linux"]`
6. **泛型不可协变/逆变**：`ConcurrentSkipListMap<ByteArray, EntryValue>` 类型精确匹配
7. **Duration 转纳秒**：`expire.toNanoseconds()` 返回 Int64，需注意溢出；`DateTime.now().toUnixTimestamp()` 也为纳秒级 Int64
8. **IOUringStream 构造需 fd**：Linux 下先 `File(path, mode)` 获取 fd，再 `IOUringStream(fd, entries)`，必须保持 File 对象存活

### 9.4 性能优化方向（后续迭代）

1. **SSTable Data Block 压缩**：Snappy/LZ4 压缩减少磁盘占用
2. **Block Cache**：LRU 缓存热点 Data Block，减少磁盘读取
3. **BloomFilter 序列化**：扩展 f_bloom 支持直接序列化/反序列化
4. **WAL 批量提交**：攒多条记录后一次 IOUringStream.flush()
5. **Compaction 分层策略优化**：Leveled/Tiered/Hybrid 策略选择
6. **前缀压缩（Prefix Compression）**：SSTable 中相邻 key 共享前缀，减少存储
7. **IoUringPool 多 ring**：为 SSTable 读取使用 IoUringPool 轮询多 ring 实例
8. **Registered Buffers**：IOUringStream 启用注册缓冲区模式，减少内核地址验证开销
9. **IOUringBufferRing**：使用 Provided Buffer Ring 替代手动缓冲区管理
10. **主动过期清理**：后台线程定期扫描 MemTable 和 SSTable 清理过期数据，减少存储占用

---

## 10. 模块依赖

```
f_store
├── f_base          (Path, unsafeBytes, mcopy, AtomicInt64扩展)
├── f_io            (IOUringStream — 直接使用，无需底层 API)
├── f_concurrent    (ConcurrentSkipListMap)
└── f_bloom         (BloomFilter)
```

**cjpm.toml 需添加**：
```toml
[dependencies]
"fountain::f_base" = {path = "../f_base"}
"fountain::f_io" = {path = "../f_io"}
"fountain::f_concurrent" = {path = "../f_concurrent"}
"fountain::f_bloom" = {path = "../f_bloom"}
```

---

## 11. 文件清单（规划）

| 文件 | 包 | 内容 |
|------|---|------|
| `src/Store.cj` | `fountain::f_store` | Store 主类、add/remove/get/ttl/prefix/close、ByteArray、EntryValue、StoreClosedException |
| `src/LSM.cj` | — | MemTable、MemTableManager、LevelManager（已迁出到独立文件） |
| `src/MemTable.cj` | `fountain::f_store` | MemTable 实现 |
| `src/MemTableManager.cj` | `fountain::f_store` | 双缓冲 MemTable 管理 |
| `src/LevelManager.cj` | `fountain::f_store` | 层级管理（无锁 AtomicReference） |
| `src/WAL.cj` | `fountain::f_store` | WAL 实现（File 同步 IO）、自动轮转 |
| `src/WALRecord.cj` | `fountain::f_store` | WAL 记录编解码 |
| `src/WALRecordCodec.cj` | `fountain::f_store` | CRC32 校验工具 |
| `src/WALReader.cj` | `fountain::f_store` | WAL 读取与崩溃恢复（std.fs.File 同步读） |
| `src/SSTable.cj` | `fountain::f_store` | SSTable 读写合并（单类 Writing→Readable 状态机） |
| `src/SSTableIterator.cj` | `fountain::f_store` | SSTable 全量/前缀遍历器 |
| `src/SSTableMerger.cj` | `fountain::f_store` | 多路归并迭代器 |
| `src/SSTableMetadata.cj` | `fountain::f_store` | SSTable 元数据（含 fileSize） |
| `src/SSTableState.cj` | `fountain::f_store` | Writing/Readable/Closed 状态枚举 |
| `src/IndexEntry.cj` | `fountain::f_store` | Data Block 索引条目 |
| `src/ByteArray.cj` | `fountain::f_store` | 有序字节数组 key |
| `src/EntryValue.cj` | `fountain::f_store` | 键值条目（含 expireAt） |
| `src/StoreClosedException.cj` | `fountain::f_store` | Store 关闭异常 |
| `src/store_func.cj` | `fountain::f_store` | 小端序工具、flushMemTable、cleanupOldWALFiles |
| `src/Compaction.cj` | `fountain::f_store` | Compaction 策略与执行 |
| `src/PrefixIterator.cj` | `fountain::f_store` | 前缀遍历迭代器、多路归并 |
