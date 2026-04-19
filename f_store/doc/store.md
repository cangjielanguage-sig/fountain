# LSM-Tree 存储引擎技术方案

## 1. 概述

基于 LSM-Tree（Log-Structured Merge-Tree）架构实现键值存储引擎，使用以下核心组件：
- **ConcurrentSkipListMap**：内存有序表（MemTable），提供无锁并发读写
- **io_uring**：异步磁盘 I/O，SSTable 写入与 WAL 持久化
- **BloomFilter**：SSTable 布隆过滤器，加速点查询

### 数据流

```
写入 → WAL(顺序写) → MemTable(跳表) → [满] → Immutable MemTable → io_uring异步刷盘 → SSTable(L0)
                                                                                    ↓
                                                                  Compaction → L1 → L2 → ...
```

### 核心约束
- add/remove/get 原子且无锁并发安全
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
        let minLen = if (bytes.size < other.bytes.size) { bytes.size } else { other.bytes.size }
        for (i in 0..minLen) {
            if (bytes[i] < other.bytes[i]) { return Ordering.LT }
            if (bytes[i] > other.bytes[i]) { return Ordering.GT }
        }
        if (bytes.size < other.bytes.size) { return Ordering.LT }
        if (bytes.size > other.bytes.size) { return Ordering.GT }
        return Ordering.EQ
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
    public init(value: ?Array<Byte>, sequence: Int64) {
        this.value = value
        this.sequence = sequence
    }
}
```

**要点**：
- `value == None` 表示 tombstone，`get` 遇到 tombstone 返回 `None`
- `sequence` 保证并发写入的全局顺序，读操作优先取高序列号
- 不可变对象，一旦创建不再修改

---

## 3. 核心组件

### 3.1 MemTable — 内存表

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
        // 更新 byteCount（近似值，允许弱一致）
        byteCount.fetchAdd(key.bytes.size + (entry.value?.size ?? 0) + 24)  // 24 = 开销估计
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

### 3.2 双缓冲 MemTable 管理

```
┌─────────────┐     满/手动flush     ┌──────────────────┐
│  MemTable   │ ──────────────────→  │ Immutable MemTable│ ──→ io_uring刷盘
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
- swap 后，immutable 是只读快照，后台线程异步刷盘
- 如果 immutable 尚未刷完而 active 又满了，需阻塞等待（背压）

**并发安全分析**：
- add/remove/get 操作只读 `active`，走 `ConcurrentSkipListMap` 的无锁路径
- swap 时 `AtomicReference` 提供原子切换，新写入自动路由到新 active
- immutable 只读，不存在并发修改问题

### 3.3 WAL — 预写日志

#### 格式设计

每个 WAL 记录：
```
┌──────────┬──────────┬──────────┬─────────────┬────────────┬────────────┐
│ checksum │ sequence │ key_len  │ value_len   │ key_bytes  │ value_bytes│
│ 4 bytes  │ 8 bytes  │ 8 bytes  │ 8 bytes     │ var        │ var        │
│ CRC32    │ Int64    │ Int64    │ Int64       │            │ 0=删除     │
└──────────┴──────────┴──────────┴─────────────┴────────────┴────────────┘
```

- `value_len = 0` 表示 tombstone（删除记录）
- `checksum` 覆盖 sequence + key_len + value_len + key_bytes + value_bytes

#### 实现架构

```cj
class WAL <: Resource {
    let fd: Int32                    // 文件描述符
    let stream: IOUringStream        // io_uring 异步写入
    let sequence: AtomicInt64        // 当前序列号
    let writeLock: Mutex             // 顺序写互斥（WAL必须顺序）

    func append(key: Array<Byte>, value: ?Array<Byte>): Int64 {
        // 1. sequence.incrFetch() 获取序列号
        // 2. 编码记录（checksum + sequence + key_len + value_len + key + value）
        // 3. stream.write(encoded) 异步写入
        // 返回序列号
    }

    func sync(): Unit {
        // ioUringPrepFsync 提交 fsync
    }

    func close(): Unit {
        // stream.close() + File.close()
    }
}
```

**要点**：
- 使用 `IOUringStream` 异步写 WAL，写操作不阻塞调用线程
- `writeLock` 保证 WAL 记录的顺序性——这是唯一需要锁的地方，但锁持有时间极短（仅编码+提交SQE）
- **为什么 WAL 需要锁而 add/remove/get 不需要**：WAL 是追加写，必须保证记录顺序与序列号一致；而 MemTable 本身无锁
- `append` 返回序列号，供 `EntryValue` 使用

**崩溃恢复**：
- 启动时读取 WAL 文件，按 sequence 排序重放到 MemTable
- 遇到损坏的 checksum 记录，截断该点之后的数据（WAL 末尾可能不完整）
- 重放完成后删除旧 WAL，创建新 WAL

#### WAL 文件管理

- 文件命名：`{path}/wal/{sequence_start}.wal`
- 刷盘完成后旧 WAL 可删除
- 多个 WAL 文件按序列号范围顺序存在

### 3.4 SSTable — 有序字符串表

#### 文件格式

```
┌─────────────────────────────────────────────────────────────────┐
│ Data Block 1                                                    │
│   key_len(8) + value_len(8) + sequence(8) + key + value/tomb   │
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
│   magic_number(8) = 0x4C534D54 ("LSMT")                         │
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
    let fd: Int32
    let metadata: SSTableMetadata   // minKey, maxKey, entryCount, level
    let bloomFilter: BloomFilter
    let indexBlock: IndexBlock
}
```

- 文件命名：`{path}/sst/L{level}_{sequence_start}_{sequence_end}.sst`
- 每个文件 ≤ 64MB，达到阈值时关闭当前文件创建新文件
- 文件创建后不可变（不修改已持久化文件）

### 3.5 SSTable 写入流程

```
Immutable MemTable → 编码记录 → io_uring 批量写入 → fsync → 创建 BloomFilter → 写 Footer → 关闭文件
```

```cj
class SSTableWriter {
    let stream: IOUringStream
    let bloomFilter: BloomFilter
    let indexEntries: ArrayList<IndexEntry>
    var currentOffset: Int64
    var entryCount: Int64
    var fileSize: Int64    // 不超过 64MB

    func write(key: ByteArray, entry: EntryValue): Unit {
        // 1. 编码 key_len + value_len + sequence + key + value/tomb
        // 2. 记录 Index Entry（如果新 Data Block）
        // 3. bloomFilter.add(key.bytes)
        // 4. stream.write(encoded)
        // 5. currentOffset += encoded.size
        // 6. entryCount++
        // 7. fileSize += encoded.size
    }

    func finish(): SSTableMetadata {
        // 1. 写 Index Block
        // 2. 写 Bloom Filter Block
        // 3. 写 Footer
        // 4. fsync
        // 返回元数据
    }

    func isFull(): Bool {
        fileSize >= MAX_SSTABLE_SIZE  // 64MB
    }
}
```

**要点**：
- 使用 `IOUringStream` 的异步写路径，`write` 立即返回不阻塞
- `finish` 时调用 `fsync` 确保数据落盘
- 单文件超过 64MB 时停止写入，创建新文件

### 3.6 SSTable 读取

```cj
class SSTableReader {
    let metadata: SSTableMetadata
    let bloomFilter: BloomFilter
    let indexBlock: IndexBlock

    func get(key: ByteArray, fd: Int32): ?EntryValue {
        // 1. bloomFilter.mightContain(key.bytes) → false 则直接返回 None
        // 2. 二分查找 Index Block 定位 Data Block
        // 3. 使用 io_uring 同步读路径（readRing）读取 Data Block
        // 4. 在 Data Block 内线性/二分查找 key
        // 返回 EntryValue 或 None
    }
}
```

**要点**：
- BloomFilter 快速排除不存在 key 的 SSTable，避免不必要的磁盘 I/O
- Index Block 二分定位 Data Block，减少读取范围
- 读取使用 `IOUringStream` 的同步 read 路径（readRing + waitCQE）

### 3.7 Level 管理

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

## 4. Store 主类实现

### 4.1 类定义

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

### 4.2 初始化

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
    // 4. 创建新 WAL 文件
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

### 4.3 add — 添加键值对

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
- `wal.append` 返回序列号后，记录已提交到 io_uring 写队列
- `ConcurrentSkipListMap.add` 是原子操作（CAS）
- 写入顺序：WAL 先于 MemTable（WAL 成功后才写入 MemTable）
- 如果 WAL 写入失败（io_uring 返回错误），不写入 MemTable，抛出异常

**并发安全**：
- `wal.append` 内部有 writeLock 保证顺序，但持有时间极短
- `ConcurrentSkipListMap.add` 无锁 CAS
- `maybeFlush` 检查是近似判断，多线程可能同时触发但 swap 有 flushLock 保护

### 4.4 remove — 删除键

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

### 4.5 get — 查询键

```cj
public func get(key: Array<Byte>): ?Array<Byte> {
    if (closed.load()) { throw StoreClosedException() }
    let keyBytes = ByteArray(key)

    // 1. 查 active MemTable
    let active = memTableManager.active.load()
    if (let Some(entry) <- active.get(keyBytes)) {
        return entry.value  // None = tombstone，返回 None 表示 key 不存在
    }

    // 2. 查 immutable MemTable（可能正在刷盘）
    if (let Some(imm) <- memTableManager.immutable.load()) {
        if (let Some(entry) <- imm.get(keyBytes)) {
            return entry.value
        }
    }

    // 3. 查 SSTable（从 L0 到 Ln，找到第一个即返回）
    let result = levelManager.get(keyBytes)
    result?.value
}
```

**查询优先级**：active MemTable > immutable MemTable > L0 SSTable > L1 SSTable > ...

**要点**：
- 找到 tombstone（`entry.value == None`）立即返回 `None`，不需要继续查找更底层
- `ConcurrentSkipListMap.get` 无锁，不影响并发写
- SSTable 查询利用 BloomFilter 快速排除

### 4.6 prefix — 前缀遍历

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
        // 4. 如果是 tombstone，跳过；否则返回 (key, value)
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

### 4.7 close — 关闭存储

```cj
public func close(): Unit {
    if (!closed.compareAndSwap(false, true)) {
        return  // 已关闭
    }

    // 1. 将 active MemTable swap 为 immutable
    let imm = memTableManager.swapActive()

    // 2. 刷 immutable MemTable 到 SSTable
    if (let Some(table) <- imm) {
        flushMemTable(table)
    }

    // 3. WAL fsync + close
    wal.sync()
    wal.close()

    // 4. 关闭所有 SSTable 文件
    levelManager.closeAll()

    // 5. 停止 Compaction 线程
    compactionThread.interrupt()
}
```

---

## 5. Compaction — 压实合并

### 5.1 触发条件

| Level | 触发条件 | 合并策略 |
|-------|---------|---------|
| L0 | SSTable 数量 ≥ 4 | L0 → L1（必须合并，因 L0 范围重叠） |
| L1 | 总大小 ≥ 10MB | L1 → L2 |
| L2 | 总大小 ≥ 100MB | L2 → L3 |
| Ln | 总大小 ≥ 10^n MB | Ln → Ln+1 |

### 5.2 Compaction 流程

```
1. 选择输入 SSTable（本层 + 下一层有范围重叠的 SSTable）
2. 多路归并排序（按 key 合并，高 sequence 优先）
3. 过滤 tombstone（被删除的 key 不写入新 SSTable）
4. 写入新的 SSTable 文件（通过 io_uring）
5. 原子替换：删除旧 SSTable，添加新 SSTable
```

```cj
class Compactor {
    let levelManager: LevelManager
    let ioUringStream: IOUringStream   // 专用于 compaction 的 io_uring

    func compact(level: Int64): Unit {
        // 1. 选择输入 SSTable
        let inputs = selectInputs(level)

        // 2. 多路归并
        let merger = SSTableMerger(inputs)

        // 3. 写入新 SSTable
        let writer = SSTableWriter(newFilePath, ioUringStream)
        while (let Some((key, entry)) <- merger.next()) {
            if (entry.value.isSome()) {  // 跳过 tombstone（仅最高层合并时）
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
- 合并时跳过 tombstone（除非该 key 可能在更底层存在，保守策略是只移除确定可清理的 tombstone）
- 新 SSTable 写完后再删除旧的，保证崩溃恢复后数据完整
- 使用独立的 `IOUringStream` 避免与 WAL/刷盘争抢 io_uring 资源

### 5.3 并发安全

- Compaction 期间，旧 SSTable 仍可被查询
- 新 SSTable 写完后，原子更新 LevelManager 中的引用
- 旧 SSTable 引用计数归零后延迟删除（避免正在读取的迭代器失效）

---

## 6. 崩溃恢复

### 6.1 恢复流程

```
启动 → 1. 扫描 SSTable 文件 → 加载元数据
      → 2. 扫描 WAL 文件 → 按 sequence 重放到 MemTable
      → 3. 截断损坏的 WAL 记录（checksum 校验失败处）
      → 4. 删除旧 WAL，创建新 WAL
      → 5. 就绪
```

### 6.2 WAL 记录读取

```cj
func recoverWAL(path: Path): MemTable {
    let table = MemTable()
    let walFiles = listWALFiles(path)  // 按序列号排序

    for (walFile in walFiles) {
        try {
            // 逐条读取 WAL 记录
            while (let Some(record) <- readNextRecord(walFile)) {
                if (verifyChecksum(record)) {
                    let entry = EntryValue(record.value, record.sequence)
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
- WAL 记录按 sequence 排序，后写入的覆盖先写入的（符合 LSM 语义）
- checksum 失败说明进程在写入过程中崩溃，截断该记录及之后所有记录
- io_uring 异步写入的记录可能未落盘——但 WAL 每次 append 后定期 fsync，最坏丢失最后一次 fsync 之后的数据

### 6.3 fsync 策略

- **每次 WAL append 后不立即 fsync**（性能代价太高）
- **定期 fsync**：每 N 次 append 或每 T 毫秒 fsync 一次
- 可配置 `syncMode`：
  - `ASYNC`：不主动 fsync（依赖内核回写，最高性能，崩溃可能丢数据）
  - `PERIODIC`：定期 fsync（平衡性能和持久性，默认）
  - `SYNC`：每次 append 后 fsync（最高持久性，性能最低）

---

## 7. io_uring 使用方案

### 7.1 io_uring 实例分配

| 用途 | io_uring 实例 | 模式 | 说明 |
|------|--------------|------|------|
| WAL 写入 | IOUringStream(fd) | 双ring：write异步+read同步 | append 走异步写路径 |
| SSTable 刷盘 | IOUringStream(fd) | 双ring | MemTable → SSTable 写入 |
| SSTable 读取 | 复用各 SSTable 的 IOUringStream | read 同步路径 | get/prefix 时读取 |
| Compaction | IOUringStream(fd) | 双ring | 合并写入新 SSTable |

### 7.2 写入优化

- 使用 `IOUringStream.write` 异步提交，不阻塞调用线程
- WAL 写入后立即返回，io_uring 后台完成实际 I/O
- SSTable 刷盘时批量写入多个 Data Block，减少 syscall

### 7.3 读取优化

- SSTable 读取使用 `IOUringStream.read` 同步路径（readRing + waitCQE）
- 先读 Footer 定位 Index Block 和 Bloom Filter
- BloomFilter 和 IndexBlock 加载后缓存在内存中（SSTableReader 持有）
- 只在需要时读取 Data Block

---

## 8. 布隆过滤器使用方案

### 8.1 创建时机

- Immutable MemTable 刷盘时，与 SSTable 同步构建 BloomFilter
- 每个 SSTable 一个 BloomFilter

### 8.2 参数选择

```cj
// 预期元素数由 MemTable 大小决定
// 误判率选择 0.01（1%），平衡内存和准确性
let filter = BloomFilter.new(estimatedCount, 0.01)
```

### 8.3 查询流程

```
get(key) → 遍历 SSTable
         → SSTableReader.get(key)
         → bloomFilter.mightContain(key.bytes)?
            → false: 跳过此 SSTable
            → true: 查 IndexBlock → 读取 DataBlock → 查找 key
```

### 8.4 持久化

- BloomFilter 参数（n, p, seeds）和位集数据写入 SSTable 的 Bloom Filter Block
- 加载 SSTable 时从文件读取并重建 BloomFilter

**BloomFilter 序列化方案**（需扩展 BloomFilter）：
```cj
// 由于 BloomFilter.bitSet 是 private，需要以下之一：
// 方案A：在 f_bloom 中添加 serialize/deserialize 方法
// 方案B：在 f_store 中使用反射或直接操作内存
// 推荐方案A，向 f_bloom 提交扩展
```

**临时方案**：SSTable 刷盘时记录所有 key，加载时重新构建 BloomFilter。虽然增加了启动时间，但避免了修改 f_bloom 模块。

---

## 9. 并发安全总结

### 9.1 操作并发矩阵

| 操作 | add | remove | get | prefix | compaction |
|------|-----|--------|-----|--------|------------|
| add | ✅无锁 | ✅无锁 | ✅无锁 | ✅无锁 | ✅ |
| remove | | ✅无锁 | ✅无锁 | ✅无锁 | ✅ |
| get | | | ✅无锁 | ✅无锁 | ✅ |
| prefix | | | | ✅无锁 | ✅ |
| compaction | | | | | 🔒后台 |

### 9.2 锁使用

| 锁 | 保护对象 | 持有时间 |
|----|---------|---------|
| WAL.writeLock | WAL 追加顺序性 | 微秒级（编码+提交SQE） |
| MemTableManager.flushLock | MemTable swap | 微秒级（引用交换） |
| LevelManager.levelLocks[n] | SSTable 列表变更 | 毫秒级（Compaction替换） |

**add/remove/get 的关键路径无锁**：ConcurrentSkipListMap 提供无锁读写，WAL 锁持有时间极短。

### 9.3 原子性保证

- **add**：WAL append + MemTable add，WAL 先写保证崩溃可恢复
- **remove**：同 add，写入 tombstone
- **get**：单次跳表查找 + SSTable 查找，天然原子

---

## 10. 实现要点与注意事项

### 10.1 关键实现要点

1. **序列号是核心**：所有操作依赖全局单调递增序列号决定数据新旧，`AtomicInt64` 分配
2. **WAL 先于 MemTable**：保证崩溃恢复时 WAL 包含所有已确认写入
3. **tombstone 不可丢弃**：除非 Compaction 确认更底层无此 key，否则保留 tombstone
4. **SSTable 不可变**：一旦创建不再修改，删除靠 tombstone，物理删除靠 Compaction
5. **64MB 文件上限**：SSTableWriter 跟踪写入大小，达到 64MB 关闭当前文件
6. **prefix 遍历范围**：利用 `tailer(minKey)` 定位起始点，遍历到 key 不以 prefix 开头为止

### 10.2 潜在问题与对策

| 问题 | 对策 |
|------|------|
| io_uring 异步写未落盘时崩溃 | WAL 定期 fsync，可配置同步策略 |
| ConcurrentSkipListMap 弱一致 size | byteCount 是近似值，不影响正确性 |
| L0 SSTable 范围重叠，查询慢 | L0 数量阈值触发 Compaction |
| BloomFilter 无法序列化 bitSet | 临时方案：启动时重建；长期：扩展 f_bloom |
| 多线程同时触发 flush | flushLock 保证只有一个线程执行 swap |
| Compaction 期间查询旧 SSTable | 引用计数或延迟删除，保证读取完整性 |
| fd 在 File 关闭后失效 | IOUringStream 生命周期内保持 File 对象存活 |
| WAL 写入 io_uring 返回错误 | 抛出异常，不写入 MemTable，上层可重试 |
| ByteArray 的 Array<Byte> 比较性能 | 逐字节比较，可考虑缓存 hashCode |

### 10.3 仓颉语言特殊注意

1. **lambda 不可捕获可变变量**：Compaction 状态机使用自定义类而非闭包
2. **函数参数不可变**：`add(key: Array<Byte>, value: Array<Byte>)` 中 key/value 不可重新赋值
3. **try-with-resource 要求 Resource 接口**：Store、WAL、SSTableFile 需实现 `Resource`
4. **File 对象关闭后 fd 失效**：IOUringStream 使用 fd 期间保持 File 存活
5. **条件编译**：io_uring 相关代码需 `@When[os == "Linux"]`
6. **泛型不可协变/逆变**：`ConcurrentSkipListMap<ByteArray, EntryValue>` 类型精确匹配

### 10.4 性能优化方向（后续迭代）

1. **SSTable Data Block 压缩**：Snappy/LZ4 压缩减少磁盘占用
2. **Block Cache**：LRU 缓存热点 Data Block，减少磁盘读取
3. **BloomFilter 序列化**：扩展 f_bloom 支持直接序列化/反序列化
4. **WAL 批量提交**：攒多条记录后一次 io_uring submit
5. **Compaction 分层策略优化**：Leveled/Tiered/Hybrid 策略选择
6. **前缀压缩（Prefix Compression）**：SSTable 中相邻 key 共享前缀，减少存储

---

## 11. 模块依赖

```
f_store
├── f_base          (Path, unsafeBytes, mcopy, AtomicInt64扩展)
├── f_io            (IOUringStream, MMapFile)
│   └── f_io.uring  (IoUring, IoUringLockFree, SQE prep, CQE read)
│       └── lockfree (IoUringLockFree, CompletionSlotArray, LockFreeCQEReaper)
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

## 12. 文件清单（规划）

| 文件 | 包 | 内容 |
|------|---|------|
| `src/Store.cj` | `fountain::f_store` | Store 主类、ByteArray、EntryValue |
| `src/LSM.cj` | `fountain::f_store` | MemTable、MemTableManager、LevelManager |
| `src/WAL.cj` | `fountain::f_store` | WAL 实现、记录编解码、崩溃恢复 |
| `src/SSTable.cj` | `fountain::f_store` | SSTable 读写、文件格式、BloomFilter 持久化 |
| `src/Compaction.cj` | `fountain::f_store` | Compaction 策略与执行 |
| `src/PrefixIterator.cj` | `fountain::f_store` | 前缀遍历迭代器、多路归并 |
