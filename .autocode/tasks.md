# 前置任务
cd f_store

# 任务

技术方案详见 ./f_store/doc/store.md

---

## ✅ Step 1: 基础数据结构 — ByteArray + EntryValue + 异常类

**文件**: `src/Store.cj`
**包**: `fountain::f_store`

### 开发内容
1. **ByteArray** — `public struct ByteArray <: Comparable<ByteArray>`
   - 构造函数 `ByteArray(public let bytes: Array<Byte>)`
   - `compare(other: ByteArray): Ordering` — 逐字节比较，短前缀为小，全等则相等
   - 实现 `Hashable` 接口（`hashCode()`）— 可用 `HashBuilder` 或简单累加
   - 实现 `Equatable<ByteArray>` 接口（`==` 和 `!=`）
   - **注意**: struct 值类型，Array<Byte> 是引用，比较时按内容而非引用
   - **注意**: 仓颉 struct 中 `mut func` 才能修改成员，ByteArray 不可变不需要

2. **EntryValue** — `public class EntryValue`
   - `public let value: ?Array<Byte>` — None 表示 tombstone
   - `public let sequence: Int64` — 全局单调递增序列号
   - `public let expireAt: ?Int64` — 过期时间戳（纳秒），None = 永不过期
   - `public init(value: ?Array<Byte>, sequence: Int64, expireAt!: ?Int64 = None)`
   - 不可变对象，所有字段 `let`

3. **StoreClosedException** — `public class StoreClosedException <: Exception`
   - Store 关闭后操作抛出此异常

### 测试
- ByteArray 比较逻辑：空数组、前缀关系、不等字节、相等
- ByteArray 作为 ConcurrentSkipListMap key 的正确性
- EntryValue 构造和字段访问（含 expireAt）

---

## ✅ Step 2: IO 工厂函数 — createStoreStream

**文件**: `src/Store.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **createStoreStream** — 工厂函数，返回 `IOStream`
   ```cj
   @When[os == "Linux"]
   public func createStoreStream(path: String, mode: OpenMode, entries!: UInt32 = 64): IOStream {
       let file = File(path, mode)
       IOUringStream(Int32(file.fileDescriptor.fileHandle), entries)
   }
   @When[os != "Linux"]
   public func createStoreStream(path: String, mode: OpenMode, entries!: UInt32 = 64): IOStream {
       File(path, mode)  // File 本身实现 IOStream
   }
   ```

### 设计说明
- 直接使用 `fountain::f_io.IOUringStream`（双 ring 架构：写 ring 异步 + 读 ring 同步），不再自定义 IO 封装
- `IOUringStream` 已实现 `IOStream & Resource`，提供 `write`/`read`/`flush`/`close`/`isClosed`
- 非 Linux 下 `std.fs.File` 已实现 `IOStream & Seekable & Resource`，直接使用
- 返回类型统一为 `IOStream`，调用方不关心底层实现

### IOUringStream 能力映射
| IOUringStream 方法 | f_store 用途 |
|-------------------|-------------|
| `write()` — 异步提交写 SQE，后台收割线程处理 CQE | WAL 追加、SSTable 刷盘、Compaction 写入 |
| `read()` — 同步 submit + waitCQE | SSTable 点查询 |
| `flush()` — `IOSQE_IO_DRAIN` + fsync + `LockFreePromise` 等待 | WAL 定期 fsync、SSTable 写完 fsync |
| `close()` — 停止收割线程 + 关闭双 ring | 关闭 WAL/SSTable 文件 |

### 注意事项
- **File 对象必须保持存活**，否则 fd 失效。Linux 下 `createStoreStream` 内部创建 File 后将其引用传递给 IOUringStream，但 **IOUringStream 只持有 fd 不持有 File**，调用方必须保持 File 存活
- `flush()` 语义：Linux 下执行 fsync；非 Linux 下 `File.flush()` 为 no-op
- **import (Linux)**: `fountain::f_io.IOUringStream`
- **import (非Linux)**: `std.fs.*`, `std.io.*`

### 测试
- Linux: createStoreStream → write → read → flush → close，数据正确
- 非 Linux: createStoreStream → write → read → flush → close，数据正确
- 验证 flush 后数据持久化
- **测试也需条件编译**: `@When[os == "Linux"]` 包裹 io_uring 相关测试

---

## ✅ Step 3: MemTable — 内存表

**文件**: `src/LSM.cj`
**包**: `fountain::f_store`

### 开发内容
1. **MemTable** — `class MemTable`
   - `let table: ConcurrentSkipListMap<ByteArray, EntryValue>` — 核心跳表
   - `let byteCount: AtomicInt64` — 近似内存占用（弱一致性可接受）
   - `init()` — 创建空跳表
   - `func add(key: ByteArray, entry: EntryValue): ?EntryValue` — 委托跳表 add，更新 byteCount
   - `func get(key: ByteArray): ?EntryValue` — 委托跳表 get
   - `func iterator(): Iterator<(ByteArray, EntryValue)>` — 全量有序遍历
   - `func tailer(min: ByteArray): Iterator<(ByteArray, EntryValue)>` — 从 min 开始遍历
   - `func approximateSize(): Int64` — 返回 byteCount

### 注意事项
- byteCount.fetchAdd 是近似值，多线程可能有小偏差，不影响正确性
- ConcurrentSkipListMap 的 add 返回旧值 Option<V>，需正确处理
- `tailer` 的 `including` 参数默认 true
- **import**: `fountain::f_concurrent.ConcurrentSkipListMap`

### 测试
- 单线程 add/get 基本正确性
- 多线程并发 add 不崩溃、不丢数据
- iterator 和 tailer 遍历结果有序
- byteCount 近似准确

---

## ✅ Step 4: MemTableManager — 双缓冲管理

**文件**: `src/LSM.cj`（追加到同文件）
**包**: `fountain::f_store`

### 开发内容
1. **MemTableManager** — `class MemTableManager`
   - `let active: AtomicReference<MemTable>` — 当前可写 MemTable
   - `let immutable: AtomicReference<?MemTable>` — 刷盘中的只读快照，初始 None
   - `let flushLock: Mutex` — 仅保护 swap 操作
   - `init()` — 创建初始 active，immutable 为 None
   - `func swapActive(): ?MemTable` — 获取 flushLock → 将 active 设为 immutable → 创建新 active → 释放锁 → 返回旧 active
   - `func getActive(): MemTable` — 返回 active.load()
   - `func getImmutable(): ?MemTable` — 返回 immutable.load()

### 并发安全分析
- add/remove/get 只读 `active`（AtomicReference.load），无锁
- swap 时 flushLock 保护引用交换（微秒级），不阻塞读写
- swap 后新写入自动路由到新 active
- **背压**: 如果 immutable 非空（正在刷盘）而 active 又满，需阻塞等待 immutable 刷完

### 注意事项
- 仓颉 `AtomicReference` 在 `std.sync` 包中
- `Mutex` 也在 `std.sync` 包中
- `AtomicReference<MemTable>` 的 load/compareAndSwap 操作

### 测试
- swap 后 active 是新 MemTable，immutable 是旧的
- 并发 add 期间 swap 不丢数据
- 连续 swap 两次，第二次的 immutable 是第一次的 active

---

## ✅ Step 5: WAL 记录编解码

**文件**: `src/WAL.cj`
**包**: `fountain::f_store`

### 开发内容
1. **WALRecord** — `struct WALRecord`
   - `let checksum: UInt32` — CRC32 校验
   - `let sequence: Int64` — 序列号
   - `let key: Array<Byte>` — 键
   - `let value: ?Array<Byte>` — 值，None 表示 tombstone
   - `let expireAt: ?Int64` — 过期时间戳（纳秒），None = 永不过期
   - `func encode(): Array<Byte>` — 编码为字节数组
   - `static func decode(bytes: Array<Byte>): ?WALRecord` — 解码，checksum 不匹配返回 None

2. **编码格式**（小端序）:
   ```
   checksum(4) + sequence(8) + key_len(8) + value_len(8) + expire_at(8) + key_bytes(key_len) + value_bytes(value_len)
   ```
   - value_len = 0 表示 tombstone
   - expire_at = 0 表示永不过期，非零为纳秒级过期时间戳
   - checksum 覆盖 sequence + key_len + value_len + expire_at + key_bytes + value_bytes

3. **WALRecordCodec** — 编解码工具类
   - `static func computeChecksum(data: Array<Byte>): UInt32` — CRC32
   - **CRC32 实现**: 优先使用 `std.crypto.digest` 中的 CRC32；若不可用则自行实现查表法

### 注意事项
- 仓颉 `Array<Byte>` 构造需指定 repeat 参数
- 字节序统一小端序（与 x86/ARM 一致）
- Int64 → 字节数组需手动移位拆分（仓颉无 ByteBuffer）
- 解码时需校验 bytes 长度是否足够，不够则返回 None
- `?Array<Byte>` 序列化时 value_len=0 表示 None
- `?Int64` 序列化时 expire_at=0 表示 None

### 测试
- 编码→解码往返一致性
- tombstone（value=None）编解码
- 含 expireAt 的编解码
- expireAt=None 时 expire_at=0
- 篡改 checksum 后解码返回 None
- 边界：空 key、空 value（非 None）、大 key+大 value

---

## ✅ Step 6: WAL 写入实现

**文件**: `src/WAL.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **WAL (Linux)** — `@When[os == "Linux"] class WAL <: Resource`
   - `private let file: File` — 保持 File 存活（fd 依赖它）
   - `private let stream: IOUringStream` — 双 ring：写 ring 异步 + 读 ring 同步
   - `let sequence: AtomicInt64` — 当前序列号
   - `let appendCount: AtomicInt64` — 追加计数（用于定期 flush）
   - `let closed: AtomicBool`
   - `private let syncInterval: Int64` — 每 N 次 append 执行一次 flush（默认 100）

   - `init(path: String, startSequence!: Int64 = 0)`
     - 创建目录 → File(path, OpenMode.ReadWrite) → IOUringStream(Int32(file.fileDescriptor.fileHandle), 64)

   - `func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64`
     ```
     seq = sequence.incrFetch()
     record = WALRecord(seq, key, value, expireAt)
     encoded = record.encode()
     stream.write(encoded)  // ★ 异步提交写 SQE，立即返回
     appendCount.incrFetch()
     if (appendCount % syncInterval == 0) { sync() }
     return seq
     ```

   - `func sync(): Unit`
     - `stream.flush()`  // IOSQE_IO_DRAIN + fsync，等所有先前写完成

   - `func close(): Unit`
     - `stream.close()`  // 停止收割线程 + 关闭双 ring
     - `file.close()`

   - `func isClosed(): Bool`

2. **WAL (非 Linux)** — `@When[os != "Linux"] class WAL <: Resource`
   - `private let file: File`
   - `let sequence: AtomicInt64`
   - `let appendCount: AtomicInt64`
   - `let closed: AtomicBool`
   - `private let syncInterval: Int64`

   - `init(path: String, startSequence!: Int64 = 0)`
   - `func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64` — 编码 → `file.write(encoded)` 同步写 → 定期 `file.flush()`
   - `func sync(): Unit` — `file.flush()`
   - `func close(): Unit` — `file.close()`
   - `func isClosed(): Bool`

### 关键设计
- **直接使用 IOUringStream**，不再自定义 IoUringLockFree + IoUring + 收割线程
- IOUringStream 内部 `writeMutex` 保证 SQE 提交顺序，WAL 无需额外锁
- `stream.flush()` 执行 `IOSQE_IO_DRAIN` + fsync，语义正确（等所有先前写完成后再 fsync）
- ★ **append 提交 SQE 后立即返回**，不等 IO 落盘完成

### 注意事项
- **File 对象必须保持存活**，否则 fd 失效
- IOUringStream 构造只接收 fd，不持有 File 引用，WAL 类必须保持 file 字段
- **条件编译**: Linux 和非 Linux 两个版本
- **import (Linux)**: `fountain::f_io.IOUringStream`

### 测试
- Linux: 写入多条记录 → 读取文件验证内容正确
- 非 Linux: 同上
- flush 后文件大小不为 0
- close 后 WAL 资源释放
- ★ 验证 append 立即返回（不等 IO 完成）

---

## ✅ Step 7: WAL 读取与崩溃恢复

**文件**: `src/WAL.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **WALReader** — `class WALReader`（无平台差异，全部使用 std.fs.File 同步读）
   - `static func readAll(path: String): ArrayList<WALRecord>` — 读取 WAL 文件所有完整记录
   - `static func recover(path: String): MemTable` — 从 WAL 恢复到 MemTable
   - 读取使用 `std.fs.File` 同步读取（不用 io_uring，恢复是启动时一次性操作）

2. **readAll 流程**:
   ```
   打开文件 → 循环:
     读取 checksum(4) + sequence(8) + key_len(8) + value_len(8) + expire_at(8) = 36 bytes
     如果读到 EOF 或不足 36 bytes → 停止
     读取 key_bytes(key_len) + value_bytes(value_len)
     如果不足 → 停止（截断的记录）
     验证 checksum → 不匹配则停止（截断）
     加入结果列表
   → 关闭文件 → 返回
   ```

3. **recover 流程**:
   ```
   扫描 {path}/wal/ 目录 → 按 sequence_start 排序
   对每个 WAL 文件: readAll → 写入 MemTable
     EntryValue(record.value, record.sequence, expireAt: record.expireAt)
   返回 MemTable
   ```

### 注意事项
- WAL 末尾可能有不完整记录（进程崩溃时 io_uring 异步写未完成），需优雅截断
- 多个 WAL 文件按文件名中的 sequence_start 排序
- 恢复到 MemTable 时，相同 key 后写入的覆盖先写入的（ConcurrentSkipListMap.add 自动覆盖）
- **import**: `std.fs.*`, `std.io.*`

### 测试
- 写入 N 条记录 → 模拟截断（删除文件末尾几个字节）→ 恢复得到前 M 条完整记录
- 空 WAL 文件恢复得到空 MemTable
- 多个 WAL 文件恢复顺序正确
- 含 expireAt 的记录恢复正确

---

## ✅ Step 8: SSTable 文件格式 — 写入（已合并为 SSTable 类，见 SSTable.cj）

**文件**: `src/SSTable.cj`
**包**: `fountain::f_store`

### 开发内容
1. **SSTableMetadata** — `class SSTableMetadata`
   - `let minKey: ByteArray` — 最小 key
   - `let maxKey: ByteArray` — 最大 key
   - `let entryCount: Int64` — 记录数
   - `let level: Int64` — 所在层级
   - `let sequenceStart: Int64` — 最小序列号
   - `let sequenceEnd: Int64` — 最大序列号
   - `let filePath: String` — 文件路径

2. **IndexEntry** — `struct IndexEntry`
   - `let offset: Int64` — Data Block 在文件中的偏移
   - `let firstKey: ByteArray` — 该 Data Block 的最小 key

3. **SSTableWriter** — `class SSTableWriter`
   - `let file: File` — 保持 File 存活（Linux: fd 依赖它）
   - `let stream: IOStream` — Linux: IOUringStream，非 Linux: File
   - `let bloomFilter: BloomFilter` — 刷盘时同步构建
   - `let indexEntries: ArrayList<IndexEntry>`
   - `var currentOffset: Int64`
   - `var entryCount: Int64`
   - `var fileSize: Int64`
   - `var dataBlockSize: Int64` — 当前 Data Block 大小
   - `let dataBlockSizeThreshold: Int64` — 单个 Data Block 大小阈值（默认 4KB）
   - `var firstKeyOfBlock: ?ByteArray`

   - `init(path: String, estimatedCount: Int64)` — `createStoreStream(path, OpenMode.ReadWrite)` + BloomFilter
   - `func write(key: ByteArray, entry: EntryValue): Unit` — 写入一条记录
   - `func finish(): SSTableMetadata` — 写 Index+Bloom+Footer，flush，关闭
   - `func isFull(): Bool` — fileSize >= 64MB

4. **write 流程**:
   ```
   如果 dataBlockSize == 0（新块开始）:
     记录 IndexEntry(currentOffset, key)
   编码: key_len(8) + value_len(8) + sequence(8) + expire_at(8) + key_bytes + value_bytes
   bloomFilter.add(key.bytes)
   stream.write(encoded)  // Linux: IOUringStream 异步写；非 Linux: File 同步写
   更新 currentOffset, fileSize, dataBlockSize, entryCount
   如果 dataBlockSize >= threshold: dataBlockSize = 0
   ```

5. **finish 流程**:
   ```
   写 Index Block + Bloom Filter Block + Footer (固定 48 bytes)
   stream.flush()  // Linux: IOSQE_IO_DRAIN + fsync; 非 Linux: file.flush()
   stream.close()
   ```

### 设计说明
- **直接使用 IOStream**（通过 `createStoreStream` 工厂创建），SSTableWriter 不关心底层是 IOUringStream 还是 File
- Linux 下通过 IOUringStream 实现异步写（写 ring 异步提交 + 后台收割线程）
- `stream.flush()` 替代原来的 `stream.sync()`，语义一致

### 注意事项
- **64MB 上限**: `MAX_SSTABLE_SIZE = 64 * 1024 * 1024`
- Data Block 按 4KB 切分，每个块对应一个 IndexEntry
- **BloomFilter 临时方案**: finish 时只序列化 n/p/seeds 到 Bloom Filter Block，bitset 启动时重建
- value_len = 0 表示 tombstone，与 WAL 格式一致
- expire_at = 0 表示永不过期，与 WAL 格式一致
- **File 对象必须保持存活**（Linux 下 fd 依赖它），SSTableWriter 持有 file 字段

### 测试
- 写入若干条记录 → finish → 文件存在且大小合理
- isFull 在 64MB 时返回 true
- 同一个 writer 连续 write 不出错

---

## ✅ Step 9: SSTable 文件格式 — 读取（已合并为 SSTable 类，见 SSTable.cj）

**文件**: `src/SSTable.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **SSTableReader** — `class SSTableReader`
   - `let metadata: SSTableMetadata`
   - `let bloomFilter: BloomFilter` — 从文件加载或重建
   - `let indexEntries: ArrayList<IndexEntry>` — Index Block 缓存在内存
   - `let stream: IOStream` — Linux: IOUringStream，非 Linux: File

   - `static func open(path: String): SSTableReader` — 打开文件，读取 Footer，加载 Index 和 BloomFilter
   - `func get(key: ByteArray): ?EntryValue` — 点查询
   - `func iterator(): Iterator<(ByteArray, EntryValue)>` — 全量有序遍历
   - `func tailer(min: ByteArray): Iterator<(ByteArray, EntryValue)>` — 从 min 开始遍历
   - `func close(): Unit`

2. **open 流程**:
   ```
   stream = createStoreStream(path, OpenMode.Read)
   读取 Footer (最后 48 bytes):
     验证 magic → 解析 index_offset, index_size, bloom_offset, bloom_size, entry_count
   读取 Index Block → 解码为 ArrayList<IndexEntry>
   读取 Bloom Filter Block → 解码 n, p, seeds → 重建 BloomFilter
   （临时方案: 遍历所有 Data Block 的 key 重建 bitset）
   构造 SSTableMetadata
   ```

3. **get 流程**:
   ```
   bloomFilter.mightContain(key.bytes) → false → return None
   二分查找 indexEntries 定位 Data Block
   stream.read(buffer) 读取 Data Block
   在记录中查找 key → 返回 EntryValue 或 None
   ```

4. **Data Block 读取**:
   - 通过 `stream.read(buffer)` 统一接口
   - Linux: IOUringStream 内部读 ring 的 submit + waitCQE（同步读）
   - 非 Linux: File.read（同步读）
   - 需先 seek 到目标偏移（设置 `stream.readOffset`）

### 设计说明
- **直接使用 IOStream**（通过 `createStoreStream` 工厂创建），SSTableReader 不关心底层实现
- 读取路径统一为同步语义（无论底层是 IOUringStream 还是 File）

### 注意事项
- IOUringStream 需暴露 `readOffset` 属性用于 seek（IOUringStream 已有此字段）
- BloomFilter 重建的临时方案增加了启动时间，后续可优化
- 二分查找 IndexEntry 时，`firstKey <= key` 用 `compare` 判断

### 测试
- 写入 SSTable → 读取 → get 验证每条记录
- get 不存在的 key 返回 None
- BloomFilter 排除不存在的 key
- tailer 从指定 key 开始遍历

---

## ✅ Step 10: SSTableFile — SSTable 文件管理（已合并为 SSTable 类，见 SSTable.cj）

**文件**: `src/SSTable.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **SSTableFile** — `class SSTableFile <: Resource`
   - `let reader: SSTableReader`
   - `let metadata: SSTableMetadata` — 便捷访问
   - `let bloomFilter: BloomFilter` — 便捷访问
   - `func get(key: ByteArray): ?EntryValue` — 委托 reader
   - `func close(): Unit` — 委托 reader.stream.close()
   - `func isClosed(): Bool`

2. **SSTableFile 命名规则**:
   - `L{level}_{sequenceStart}_{sequenceEnd}.sst`
   - 解析文件名提取 level 和 sequence 范围

3. **目录扫描**:
   - `static func loadAll(sstDir: String): ArrayList<SSTableFile>` — 扫描目录加载所有 SSTable

### 注意事项
- SSTableFile 持有 IOStream，需在 close 时正确释放
- 每个 SSTableFile 打开一个 IOStream 实例
- 文件名解析需容错：不符合命名规则的文件跳过

### 测试
- 创建多个 SSTable → loadAll 加载 → get 验证
- close 后 isClosed 返回 true

---

## ✅ Step 11: LevelManager — 层级管理（已更新：SSTableFile → SSTable）

**文件**: `src/LSM.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **LevelManager** — `class LevelManager`
   - `let sstDir: String`
   - `var levels: Array<ArrayList<SSTableFile>>` — levels[0]=L0, levels[1]=L1, ...
   - `let levelCount: Int64` — 层数（默认 7）
   - `let levelLocks: Array<Mutex>`

   - `init(sstDir: String, levelCount!: Int64 = 7)`
   - `func loadExisting(): Unit`
   - `func get(key: ByteArray): ?EntryValue` — 从 L0 到 Ln 逐层查找
   - `func addSSTable(level: Int64, sst: SSTableFile): Unit`
   - `func removeSSTables(level: Int64, toRemove: ArrayList<SSTableFile>): Unit`
   - `func getSSTablesForCompaction(level: Int64): ArrayList<SSTableFile>`
   - `func getOverlappingSSTables(level: Int64, min: ByteArray, max: ByteArray): ArrayList<SSTableFile>`
   - `func shouldCompact(level: Int64): Bool`
   - `func closeAll(): Unit`

2. **get 查询逻辑**（含过期检查）:
   ```
   for level in 0..levelCount:
     if level == 0: 遍历所有 L0 SSTable
     else: 二分查找范围匹配的 SSTable
     找到 entry:
       if entry.expireAt != None && entry.expireAt <= now: 返回 None（已过期）
       if entry.value == None: 返回 None（tombstone）
       else: 返回 entry.value
   返回 None
   ```

3. **Compaction 触发条件**:
   - L0: SSTable 数量 ≥ 4
   - Ln (n≥1): 总大小 ≥ 10^n MB

### 测试 ✅
- ✅ 加载多个 L0 SSTable → get 在所有 L0 文件中查找
- ✅ addSSTable 后 shouldCompact 返回 true
- ✅ get 的优先级：L0 > L1 > L2
- ✅ 过期数据 get 返回 None

---

## ✅ Step 12: MemTable 刷盘 — Immutable MemTable → SSTable

**文件**: `src/LSM.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **flushMemTable 函数**:
   ```cj
   func flushMemTable(memTable: MemTable, sstDir: String, level: Int64): ArrayList<SSTableMetadata>
   ```
   - 遍历 MemTable 的 iterator（有序）
   - 逐条写入 SSTableWriter
   - 如果 isFull() → finish 当前 SSTable → 创建新 writer
   - 返回所有生成的 SSTableMetadata 列表

2. **刷盘流程**:
   ```
   遍历 memTable.iterator() →
     writer.write(key, entry) →  // Linux: IOUringStream 异步写
     if writer.isFull():
       metadata = writer.finish()  // 内含 stream.flush()
       加入结果列表
       创建新 writer
   → 最后一个 writer.finish()
   → 返回所有 metadata
   ```

3. **刷盘后处理**:
   - 将新 SSTable 注册到 LevelManager (L0)
   - 删除已刷盘的 WAL 文件
   - 清空 immutable 引用

### 注意事项
- MemTable 遍历期间可能有并发读取，但 MemTable 是 immutable（只读），无冲突
- 超过 64MB 时需创建多个 SSTable 文件
- **IOStream 生命周期**: SSTableWriter 关闭时 stream 才关闭

### 测试
- 小 MemTable（< 64MB）刷盘生成 1 个 SSTable → 内容正确
- 大 MemTable 刷盘生成多个 SSTable（每个 ≤ 64MB）
- 刷盘后 LevelManager.get 能查到数据

---

## Step 13: Store 主类 — 初始化 + add/remove/get/add(expire)/ttl

**文件**: `src/Store.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **Store** — `public class Store <: Resource`
   - `private let path: Path`
   - `private let memTableManager: MemTableManager`
   - `private let wal: WAL`
   - `private let levelManager: LevelManager`
   - `private let sequence: AtomicInt64` — 全局序列号
   - `private let closed: AtomicBool`
   - `private let memFlushThreshold: Int64` — 默认 8MB

   - `public init(path: String)` — 委托主构造函数
   - `public Store(private let path: Path)`:
     ```
     创建目录 {path}/wal/ 和 {path}/sst/
     从 WAL 恢复 MemTable → 设为 active
     加载已有 SSTable → LevelManager.loadExisting()
     创建新 WAL 文件（Linux: IOUringStream，非 Linux: File）
     atExit(this.close)
     ```
   - `public func add(key: Array<Byte>, value: Array<Byte>): ?Array<Byte>`
   - `public func add(key: Array<Byte>, value: Array<Byte>, expire: Duration): ?Array<Byte>`
   - `public func ttl(key: Array<Byte>, expire: Duration): Unit`
   - `public func remove(key: Array<Byte>): ?Array<Byte>`
   - `public func get(key: Array<Byte>): ?Array<Byte>`
   - `public func isClosed(): Bool`

2. **add(key, value) 实现**:
   ```
   检查 closed →
   seq = wal.append(key, value) →
   entry = EntryValue(value, seq) →
   old = memTableManager.getActive().add(ByteArray(key), entry) →
   maybeFlush() →
   return old?.value
   ★ add 在 WAL 写入 + MemTable 修改后即可返回
   ```

3. **add(key, value, expire) 实现**:
   ```
   检查 closed →
   expireAt = DateTime.now().toUnixTimestamp() + expire.toNanoseconds()
   seq = wal.append(key, value, expireAt: expireAt) →
   entry = EntryValue(value, seq, expireAt: expireAt) →
   old = memTableManager.getActive().add(ByteArray(key), entry) →
   maybeFlush() →
   if (let Some(oldEntry) <- old):
     if (let Some(oldExpire) <- oldEntry.expireAt):
       if (oldExpire <= DateTime.now().toUnixTimestamp()): return None  // 旧值已过期
     return oldEntry.value
   else: return None
   ```

4. **ttl(key, expire) 实现**:
   ```
   检查 closed →
   expireAt = DateTime.now().toUnixTimestamp() + expire.toNanoseconds()
   查找当前值（active → immutable → SSTable）→
   如果 key 不存在或已删除: return
   用当前 value + 新 expireAt 重新写入:
     seq = wal.append(key, e.value, expireAt: expireAt)
     entry = EntryValue(e.value, seq, expireAt: expireAt)
     memTableManager.getActive().add(ByteArray(key), entry)
   ★ ttl 在 WAL 写入 + MemTable 修改后即可返回
   ```

5. **remove 实现**:
   ```
   检查 closed →
   seq = wal.append(key, None) →
   entry = EntryValue(None, seq) →
   old = memTableManager.getActive().add(ByteArray(key), entry) →
   maybeFlush() →
   return old?.value
   ★ remove 在 WAL 写入 + MemTable 修改后即可返回
   ```

6. **get 实现**（含过期检查）:
   ```
   检查 closed →
   keyBytes = ByteArray(key) →
   查 active MemTable:
     有值 → 检查 expireAt → 过期返回 None / tombstone 返回 None / 返回 entry.value
   查 immutable MemTable:
     同上
   查 LevelManager.get:
     同上
   返回 None
   ```

7. **maybeFlush**:
   ```
   if active.approximateSize() >= memFlushThreshold:
     imm = memTableManager.swapActive()
     if (let Some(table) <- imm):
       flushMemTable(table, sstDir, 0)
       memTableManager.immutable.store(None)
   ```

### 关键设计
- **add/remove/get/ttl 的关键路径完全无锁**：
  - `wal.append`: IOUringStream.write() 异步提交（Linux），File 同步写（非 Linux）
  - `memTableManager.getActive().add()`: ConcurrentSkipListMap CAS 无锁
  - `maybeFlush`: 仅在 swap 时短暂持 flushLock
- **add/remove/ttl 在 WAL 写入 + MemTable 修改后即可返回**，不等 IO 落盘完成
- **过期检查在 get 时惰性执行**：不主动清理过期数据，Compaction 时清理

### 注意事项
- **WAL 先于 MemTable**: wal.append 必须在 MemTable.add 之前成功
- maybeFlush 中 swapActive 可能返回 None（其他线程已 swap）
- atExit 注册 close，确保进程退出时数据持久化
- **Store 实现 Resource 接口**: 需实现 `func close(): Unit` 和 `func isClosed(): Bool`
- `expire.toNanoseconds()` 返回 Int64，需注意溢出
- `DateTime.now().toUnixTimestamp()` 为纳秒级 Int64

### 测试
- 基本 add/get 往返
- add 已有 key 返回旧值
- add(key, value, expire) 带 TTL 的添加
- ttl 更新已有 key 的过期时间
- get 对过期 key 返回 None
- remove 已有 key 返回旧值，之后 get 返回 None
- get 不存在的 key 返回 None
- 超过 memFlushThreshold 后自动刷盘，get 仍能查到数据
- 关闭后重新打开，数据仍可查到（WAL 恢复 + SSTable 加载）
- Linux: 验证 add/remove 立即返回（不等 IO 完成）

---

## Step 14: Store.close — 关闭与数据持久化

**文件**: `src/Store.cj`（追加）
**包**: `fountain::f_store`

### 开发内容
1. **close 实现**:
   ```
   if (!closed.compareAndSwap(false, true)) { return }
   // 1. swap active 为 immutable
   imm = memTableManager.swapActive()
   // 2. 刷 immutable 到 SSTable
   if (let Some(table) <- imm):
     flushMemTable(table, sstDir, 0)
   // 3. 刷 WAL 并关闭
   wal.sync()   // Linux: stream.flush(); 非 Linux: file.flush()
   wal.close()  // Linux: stream.close() + file.close(); 非 Linux: file.close()
   // 4. 关闭所有 SSTable
   levelManager.closeAll()
   ```

2. **close 语义**:
   - 把尚未存储的数据写入磁盘
   - WAL sync 确保所有异步写完成
   - 最后关闭所有打开的文件

### 注意事项
- close 必须幂等（多次调用不报错）
- compareAndSwap 保证只有一个线程执行 close
- 关闭顺序：先刷 MemTable（产生 SSTable）→ 再关 WAL → 最后关 SSTable

### 测试
- close 后 isClosed 返回 true
- close 前写入的数据，重新打开后可查到
- 多次 close 不崩溃

---

## Step 15: PrefixIterator — 前缀遍历

**文件**: `src/PrefixIterator.cj`
**包**: `fountain::f_store`

### 开发内容
1. **PeekableIterator** — `class PeekableIterator`
   - 包装一个 `Iterator<(ByteArray, EntryValue)>`
   - `func peek(): ?(ByteArray, EntryValue)` — 查看下一个但不推进
   - `func next(): ?(ByteArray, EntryValue)` — 推进并返回
   - `var buffered: ?(ByteArray, EntryValue)` — 预读缓冲

2. **PrefixIterator** — `class PrefixIterator <: Iterator<(Array<Byte>, Array<Byte>)>`
   - `let prefix: ByteArray`
   - `let sources: ArrayList<PeekableIterator>`
   - `var initialized: Bool`

   - `init(prefix: ByteArray, sources: ArrayList<PeekableIterator>)`
   - `func next(): ?(Array<Byte>, Array<Byte>)`

3. **next 流程**:
   ```
   从所有 sources 中取 peek 最小 key 的迭代器 →
   如果该 key 不以 prefix 开头 → return None →
   收集所有 sources 中 peek == 当前 key 的条目 →
   取 sequence 最高的 EntryValue →
   如果是 tombstone → 跳过 →
   如果已过期（expireAt <= now）→ 跳过 →
   否则 → 推进所有匹配的迭代器 → return (key.bytes, entry.value.getOrThrow())
   ```

4. **前缀匹配判断**:
   ```
   func startsWith(key: ByteArray, prefix: ByteArray): Bool
   if key.bytes.size < prefix.bytes.size → false
   for i in 0..prefix.bytes.size:
     if key.bytes[i] != prefix.bytes[i] → false
   → true
   ```

5. **Store.prefix 实现**:
   ```
   prefixBytes = ByteArray(prefix)
   sources = ArrayList<PeekableIterator>()
   sources.add(PeekableIterator(active.tailer(prefixBytes)))
   if immutable 非空: sources.add(PeekableIterator(immutable.tailer(prefixBytes)))
   for sst in levelManager.getSSTablesInRange(prefixBytes, prefixEnd):
     sources.add(PeekableIterator(sst.tailer(prefixBytes)))
   return PrefixIterator(prefixBytes, sources)
   ```

### 注意事项
- **prefixEnd 计算**: 将 prefix 的最后一个字节 +1，作为 tailer 的上限
- 多个源可能包含相同 key（active + SSTable），需按 sequence 去重
- ConcurrentSkipListMap.tailer 返回弱一致性迭代器，遍历期间不阻塞写
- SSTableReader.tailer 需在 Step 9 中实现
- **仓颉 lambda 不可捕获可变变量**: PeekableIterator 用 class 而非闭包实现
- **过期数据在遍历时跳过**（惰性过期）

### 测试
- 单源前缀遍历
- 多源同 key 合并（高 sequence 优先）
- tombstone 过滤
- 过期数据过滤
- 前缀不匹配时正确终止
- 并发写入期间前缀遍历不崩溃

---

## Step 16: Compaction — 后台压实合并

**文件**: `src/Compaction.cj`
**包**: `fountain::f_store`

### 开发内容
1. **Compactor** — `class Compactor`
   - `let levelManager: LevelManager`
   - `let sstDir: String`
   - `let running: AtomicBool`
   - `let stopSignal: AtomicBool`
   - `let thread: ?Thread`

   - `func start(): Unit` — 启动后台 compaction 线程
   - `func stop(): Unit` — 停止 compaction 线程
   - `func compact(level: Int64): Unit` — 执行一次 Compaction
   - `func runLoop(): Unit` — 后台线程主循环

2. **runLoop**:
   ```
   while (!stopSignal.load()):
     for level in 0..maxLevel:
       if levelManager.shouldCompact(level):
         compact(level)
     sleep(100ms)
   ```

3. **compact(level) 流程**:
   ```
   获取 level 层的 SSTable 列表（在 levelLock 保护下快照）→
   如果 level == 0: 选择所有 L0 SSTable
   否则: 选择部分 SSTable（大小优先策略）→
   获取 level+1 层范围重叠的 SSTable →
   多路归并（SSTableMerger）→
   写入新 SSTable 文件（SSTableWriter，底层走 IOStream → IOUringStream/File）→
   过滤 tombstone 和已过期数据 →
   finish 新 SSTable →
   levelManager.replace(level, oldSSTables, newSSTables) →
   删除旧 SSTable 文件
   ```

4. **SSTableMerger** — 多路归并迭代器
   - 输入: 多个 SSTableFile 的有序迭代器
   - 使用最小堆合并，相同 key 取高 sequence
   - 输出有序的 (ByteArray, EntryValue) 流

### 设计说明
- Compaction 使用 `IOStream`（通过 `createStoreStream` 创建）
- Linux 下通过 `IOUringStream` 异步写 + 后台收割
- 非 Linux 下通过 `File` 同步写

### 注意事项
- Compaction 不阻塞读写：旧 SSTable 在替换前仍可查询
- **原子替换**: levelLock 保护下的 SSTable 列表更新
- 新 SSTable 写完后才删除旧的，保证崩溃安全
- **tombstone 保留策略**: 只在最底层 Compaction 时移除 tombstone
- **已过期数据在 Compaction 时直接丢弃**
- **64MB 限制**: Compaction 输出也受 64MB 限制
- 后台线程用 `spawn { compactor.runLoop() }` 创建

### 测试
- L0 有 4 个 SSTable 时触发 Compaction → 合并为 L1
- Compaction 后查询结果不变
- Compaction 期间并发 add/get 不崩溃
- tombstone 在最底层 Compaction 时被清除
- 过期数据在 Compaction 时被清除

---

## Step 17: 集成测试与修复

**文件**: `src/Store_test.cj`（测试文件）
**包**: `fountain::f_store`

### 开发内容
1. **基本功能测试**:
   - add → get 往返验证
   - remove → get 返回 None
   - add 已有 key → 返回旧值，get 返回新值
   - add(key, value, expire) → get 在过期前返回值、过期后返回 None
   - ttl → 更新过期时间 → get 验证
   - prefix 遍历正确性
   - 空数据库 get/prefix 返回 None/空

2. **并发安全测试**:
   - 多线程并发 add 不同 key → 不丢数据
   - 多线程并发 add 相同 key → 返回值正确
   - 并发 add + get → get 要么返回旧值要么返回新值，不崩溃
   - 并发 add + prefix → prefix 不崩溃

3. **持久化与恢复测试**:
   - 写入数据 → close → 重新 open → 数据完整
   - 写入大量数据（超过 memFlushThreshold）→ 自动刷盘 → close → open → 数据完整
   - 模拟 WAL 恢复：写入 → 不 close → 重新 open → 从 WAL 恢复

4. **TTL 功能测试**:
   - add 带 expire → 等待过期 → get 返回 None
   - ttl 更新过期时间 → 等待新过期时间 → get 返回 None
   - ttl 对不存在的 key 无操作
   - 过期数据在 prefix 遍历中被跳过

5. **平台适配测试**:
   - Linux: 验证 add/remove 立即返回（异步 IO）
   - 非 Linux: 验证基本功能正常（同步 IO）

6. **边界条件测试**:
   - 空 key、空 value
   - 大 value（接近 64MB SSTable）
   - 大量 key 的 prefix 遍历
   - 连续 add 同一个 key
   - remove 不存在的 key 返回 None
   - Duration 极值（极短、极长过期时间）

7. **Bug 修复**: 根据测试结果修复发现的问题

### 注意事项
- 仓颉测试使用 `@Test + @TestCase + @Assert/@Expect`
- 测试必须在模块目录下执行: `cjpm test --no-capture-output --show-all-output`
- 需指定 timeout: `timeout 180 cjpm test --no-capture-output --show-all-output`
- io_uring 相关代码需在 Linux 上运行
- 测试创建临时目录，结束后清理

---

## Step 18: BloomFilter 序列化扩展（可选优化）

**文件**: `f_bloom/src/BloomFilter.cj`（修改外部模块）
**包**: `fountain::f_bloom`

### 开发内容
1. 在 BloomFilter 中添加序列化方法:
   - `func serialize(): Array<Byte>` — 序列化 n, p, seeds, bitSet 状态
   - `static func deserialize(bytes: Array<Byte>): BloomFilter` — 反序列化重建

2. 修改 SSTableReader 的 open 流程，使用序列化后的 BloomFilter 而非重建

### 注意事项
- 这是可选优化，Step 8/9 使用临时方案（启动时重建）也可工作
- 需修改 f_bloom 模块，确保不影响其他使用者
- bitSet 是 `Array<AtomicUInt64>`，序列化时需原子读取每个元素

---

## 开发依赖关系

```
Step 1 (ByteArray/EntryValue)
  → Step 2 (createStoreStream — IO工厂函数) ★ 替代原StoreIOStream
    → Step 3 (MemTable)
      → Step 4 (MemTableManager)
  → Step 5 (WALRecord 编解码 — 含expire_at)
    → Step 6 (WAL 写入 — IOUringStream版) ★ 重写：直接用IOUringStream
      → Step 7 (WAL 读取/恢复)
  → Step 8 (SSTable 写入 — IOStream版) ★ 重写：用IOStream
    → Step 9 (SSTable 读取 — IOStream版) ★ 重写：用IOStream
      → Step 10 (SSTableFile)
        → Step 11 (LevelManager — 含过期检查)
          → Step 12 (MemTable 刷盘)
            → Step 13 (Store 初始化+add/remove/get/add(expire)/ttl) ★ 重写：TTL+过期+IOUringStream
              → Step 14 (Store.close)
              → Step 15 (PrefixIterator — 含过期过滤)
          → Step 16 (Compaction — 含过期清理)
  → Step 17 (集成测试)
  → Step 18 (BloomFilter 序列化优化，可选)
```

**关键路径**: Step 1 → 2 → 3 → 4 → 12 → 13 → 14 → 17
**可并行**: Step 5-7 (WAL) 与 Step 8-10 (SSTable) 可并行开发
**最后集成**: Step 13-17 串行，每步依赖前一步完成

### 与原方案的主要差异

| 差异点 | 原方案 | 新方案 |
|--------|--------|--------|
| IO 层 | StoreIOStream + IOUringStoreIOStream + FileStoreIOStream | 直接用 IOUringStream / File，统一为 IOStream |
| WAL 写锁 | Mutex writeLock | IOUringStream 内部 writeMutex 保证顺序 |
| WAL IO | IoUringLockFree + IoUring + 收割线程（手动管理） | IOUringStream（双 ring + 收割线程内置） |
| TTL | 无 | add(key,value,expire) + ttl(key,expire) + 惰性过期 |
| 过期检查 | 无 | get/prefix 检查 expireAt，Compaction 清理过期数据 |
| EntryValue | value + sequence | value + sequence + expireAt |
| WAL 格式 | 无 expire_at | 含 expire_at(8 bytes) |
| SSTable 格式 | 无 expire_at | 含 expire_at(8 bytes) |
| add/remove 返回 | 等 IO 完成 | WAL 写入 + MemTable 修改后即返回 |
| 平台支持 | 仅 Linux | Linux (IOUringStream) + 非Linux (std.fs.File) |
| CQE 收割 | 自定义收割线程 | IOUringStream 内置收割线程 |
| SSTable IO | 自定义 IOUringStoreIOStream | IOStream（IOUringStream / File） |
| fsync | ring.getSQE + ioUringPrepFsync | stream.flush()（IOSQE_IO_DRAIN + fsync） |
