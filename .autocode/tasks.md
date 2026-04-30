# f_store 代码审查报告

./f_store/doc/开发计划.md 是本模块的开发计划。
./f_store/doc/store.md 是本模块的技术方案。

## 一、测试用例完善性评估

### 已覆盖的测试（共 ~82 个测试用例，全部 122 通过）

| 模块 | 测试类 | 用例数 | 覆盖场景 |
|------|--------|--------|----------|
| ByteArray / EntryValue | ByteArrayEntryValueTest | 10 | 构造函数、equality/clone、Comparable排序、tombstone、expireAt、空 key/value |
| MemTable | MemTableTest | 5 | add/get、覆盖写（高sequence覆盖低）、tombstone、iterator 有序性、approximateSize |
| MemTableManager | MemTableManagerTest | 3 | swap（活跃→不可变）、clearImmutable、swap while immutable busy |
| SSTable | SSTableTest | 22 | write+finish、tombstone写入、finish后write抛异常、finish幂等抛异常、isFull小量写入、多Block（100条）、大value（4KB）、finish后直接get（无需重开）、missing key、tombstone get、expireAt get、iterator 全量有序、iterator含tombstone、tailer（从指定key开始）、多Block下get全部正确、metadata验证、close+isClosed、close后get抛异常、open+get（重开文件）、loadAll（多文件）、loadAll空目录、loadAll不存在目录 |
| SSTableMerger | SSTableMergerTest | 6 | 双源归并有序性、同key去重取最高sequence、跳过过期数据、最底层tombstone移除、非最底层tombstone保留、空源列表 |
| Compaction | CompactionTest | 6 | start/stop、compact L0→L1、覆盖key取新值、stop幂等、compact无效level不崩溃、compact空L0不崩溃 |
| WAL | WALTest | 7 | append+恢复读取、expireAt、tombstone record、startSequence、close幂等、close后append抛异常 |
| WALRecord | WALRecordTest | 5 | 编解码往返、tombstone、expireAt、空key/value、大key(1000B)+大value(5000B) |
| WALReader | WALReaderTest | 4 | readAll+recover、截断记录处理、空文件、多文件恢复 |
| FlushMemTable | FlushMemTableTest | 3 | 小MemTable刷盘产生1个SSTable、通过LevelManager查询、tombstone+过期数据 |
| LevelManager | LevelManagerTest | 3 | 多L0文件加载查询、shouldCompact阈值、过期数据返回None |
| PrefixIterator | PrefixIteratorTest | 5 | startsWith边界、基本前缀迭代、空前缀、tombstone过滤、close后抛异常 |
| Store | StoreTest | 11 | add/get基本、覆盖写、remove、不存在的key、带TTL添加、TTL更新、TTL不存在的key、close+reopen数据持久化、多key(50条)、close幂等、close后操作抛异常 |
| StoreStream | StoreStreamTest | 1 | io_uring(Linux) / 标准文件IO 写入读出 |

### 测试缺失场景（建议补充）

#### 高优先级
1. **并发读写测试**：目前没有任何多线程并发测试。MemTable 使用 ConcurrentSkipListMap，理论上支持并发，但缺少验证。场景：
   - 多线程同时 add，验证 sequence 不冲突
   - 一边 add 一边 get，验证一致性
   - 一边 flush 一边 add（MemTableManager swap + 新写入）

2. **WAL 损坏恢复**：仅有截断记录测试。缺少：
   - CRC 校验失败场景（部分字节翻转）
   - 中间记录损坏，后续记录仍可恢复

3. **Compaction 多文件合并（>2 源）**：SSTableMerger 测试最多只有 2 个源。实际 L0 compaction 可能合并 4+ 个 SSTable 文件。缺少：
   - 3+ 源归并测试
   - L0 到 L1 compaction 的端到端测试（L1已有数据，L0有4个文件）

#### 中优先级
4. **MemTable 容量边界**：当 MemTable 达到阈值时，MemTableManager.add() 返回 false（触发 flush）。缺少此场景的测试。

5. **WAL 轮转**：WAL 达到一定大小后是否会轮转？当前测试未覆盖。

6. **Store 自动 flush 线程**：Store 启动后台 WAL flush 线程，缺少对此线程行为的测试。

#### 低优先级
7. **极端大小**：key/value 为 0 字节、接近上限大小的测试仅有 WALRecord 覆盖，SSTable、MemTable 缺少覆盖。

8. **BloomFilter 行为**：代码中未见 BloomFilter 实现，如需添加应考虑误判率测试。

---

## 二、性能优化分析

### 优化点 1：L0 查询 O(N_sstables) — **关键热点**

**现状**：`LevelManager.get()` 对 L0 层所有 SSTable 逐个调用 `.get()`。L0 层 key range 可能重叠，无法通过 min/max key 过滤。当 L0 有大量文件（如 4~8 个）时，每次查询都线性扫描全部文件。

```cangjie
// LevelManager.get() 中类似逻辑：
for (sst in level0files) {
    let result = sst.get(key)
    if (result.isSome()) { return result }
}
```

**优化方案**：
- **(A)** 对每个 L0 SSTable 建立内存 BloomFilter，先用 BloomFilter 排除不可能存在的 key，再执行 mmap 查询。可减少 90%+ 的无效磁盘访问。
- **(B)** 对 L0 文件按时间排序，优先查询最新的 SSTable（新数据覆盖旧数据），在找到第一个匹配后提前返回。当前实现已按 sequence 范围排序，但未做提前退出优化检查。
- **(C)** 激进方案：L0 文件数量达到阈值（如 4）后立即触发 Compaction（当前 needCompact 已实现），但 compaction 本身有 IO 开销，需平衡。

### 优化点 2：SSTableIterator 逐 Block 读取 — **读放大**

**现状**：`SSTableIterator.next()` 每次跨 block 时触发 mmap 切片读取。每个 Data Block 单独解码，无预取。

```cangjie
// 每次跨 block:
let blockData = mapping[blockOffset..blockEnd]
let entries = decodeDataBlock(blockData)
```

**优化方案**：
- **(A) 预取下个 Block**：当前 Block 读取完毕后，异步预取下一个 Block 的数据（利用 OS page cache 的 readahead，或手动 madvise）。
- **(B) Block 缓存**：对热点 SSTable 的 Index Block 和数据 Block 做 LRU 缓存，避免重复 mmap 解码。

### 优化点 3：ByteArray 比较开销 — **CPU 热点**

**现状**：`ByteArray` 是 struct，包装了 `Array<Byte>`。每次 `compareTo` 调用时，生成迭代器逐个字节比较。MemTable 底层 `ConcurrentSkipListMap` 大量调用比较操作。

```cangjie
public func compareTo(other: ByteArray): Int64 {
    let a = bytes
    let b = other.bytes
    let minLen = min(a.size, b.size)
    for (i in 0..minLen) {
        let cmp = Int64(a[i].toInt64() - b[i].toInt64())
        if (cmp != 0) { return cmp }
    }
    return Int64(a.size - b.size)
}
```

**优化方案**：
- **(A) 前缀缓存**：对 ByteArray 增加 `hashCode` 缓存字段，先用 hash 快速排除不相等的情况。
- **(B) 内联比较**：确保 compareTo 被 JIT/AOT 内联展开。当前逐字节循环可能无法被向量化。考虑对 >= 8 字节的后缀使用 `Int64` 比较。
- **(C) 避免复制**：`toInt64()` 和减法每次可能产生装箱。改用原生 `UInt8` 差值比较。

### 优化点 4：WAL 每次写入 syscall 开销 — **写吞吐瓶颈**

**现状**：`WAL.append()` 每次调用 `file.write()` 直接落盘。虽然有后台定期 `sync()`，但每次 append 仍产生一次 write syscall。

```cangjie
public func append(key: Array<Byte>, value: Option<Array<Byte>>, ...): Int64 {
    let record = WALRecord(seq, key, value, expireAt)
    let encoded = record.encode()
    file.write(encoded)  // 每次一次 syscall
    ...
}
```

**优化方案**：
- **(A) 用户态缓冲**：WAL 内部维护一个 `Array<Byte>` 缓冲区（如 64KB），多条记录先写入缓冲区，缓冲区满或 sync 时一次性 `file.write()`。
- **(B) 批量 append 接口**：提供 `appendBatch(entries: Array<(Key, Value)>)` 接口，一次编码一批记录后单次写入。

### 优化点 5：SSTable finishWrite() 全量排序 — **写入尾延迟**

**现状**：`finishWrite()` 阶段对全部 EntryValue 执行排序、索引构建、BloomFilter 构建、多 Block 分割编码。这导致 finish 时延迟与数据量成正比。

```cangjie
public func finishWrite(): SSTableMetadata {
    entries.sortBy(...)  // 全量排序
    // 构建 index + Bloom + 多 Block 编码 + 写 footer
}
```

**优化方案**：
- **(A) 写到即排序**：由于调用方（MemTable iterator）已按序提供数据，可保证 `write()` 调用本身有序，省去 `finishWrite()` 中的排序步骤。只需加断言/校验。
- **(B) 流式构建 Index**：每写满一个 Data Block（~4KB）就立即构建 Index Entry，而非等 finish 时批量构建。

### 优化点 6：Compaction 期间锁竞争

**现状**：`LevelManager` 在 compaction 期间持有锁，阻塞同层级的 get 操作。

**优化方案**：
- **(A)** 使用读写锁（`ReentrantReadWriteLock`），get 操作仅需读锁，compaction 替换文件列表时需写锁。
- **(B)** 文件替换使用原子引用切换（`AtomicReference<ArrayList<SSTable>>`），避免 get 路径上的锁竞争。

### 优化点 7：SSTable.open() mmap 开销 — **启动/恢复延迟**

**现状**：`SSTable.open()` 使用 mmap 映射整个文件。大量 SSTable 文件（如 100+）会导致启动时大量 mmap 调用和虚拟地址空间占用。

```cangjie
public static func open(path: String): SSTable {
    let file = File(path, OpenMode.Read)
    let mapping = file.map(FileMapMode.Read)  // mmap 整个文件
    ...
}
```

**优化方案**：
- **(A) 延迟 mmap**：open 时只读取 Footer/Index，get 时才 mmap 对应 data block 区域。
- **(B) mmap 窗口化**：对于大文件，仅 mmap index 区域；data blocks 使用 pread 按需读取。

---

## 三、总结

### 测试评分：7.5/10
- 单元测试覆盖全面，核心路径均有覆盖
- 并发测试完全缺失
- 损坏恢复测试不足
- Compaction 端到端多文件测试缺失

### 性能评分：6/10
- **最优先修复**：L0 O(N) 查询 + BloomFilter（优化1）
- **次优先**：ByteArray 比较开销（优化3）、WAL 缓冲写入（优化4）
- **可按需优化**：SSTable 预取（优化2）、mmap 延迟加载（优化7）、finishWrite 排序消除（优化5）

### 建议的优化优先级排序

| 优先级 | 优化项 | 预期收益 | 实现难度 |
|--------|--------|----------|----------|
| P0 | L0 查询加 BloomFilter | 读延迟降低 50%+ | 中 |
| P1 | ByteArray 比较内联优化 | CPU 使用降低 10-20% | 低 |
| P1 | WAL 用户态缓冲 | 写吞吐提升 2-5x | 低 |
| P2 | SSTable 延迟 mmap/预取 | 启动延迟降低 + 大文件读优化 | 中 |
| P2 | Compaction 读写锁 | 并发读性能提升 | 低 |
| P3 | finishWrite 消除排序 | 写入尾延迟降低 | 低（需确保有序保证） |

---

## 四、修复任务（按优先级排序）

### 第1阶段：关键缺陷修复（预计 3~4 人天）

#### 1.1 【P0 正确性】修复 Store.close 数据丢失竞争窗口 ✅

**文件**: `Store.cj`  
**类型**: 缺陷修复 | **预计**: 0.5 人天

**问题（B8）**：`close()` 直接 flush active MemTable 而非先 swapActive。存在极窄竞争窗口——close 启动后仍有并发 add() 通过 `guardOpen()` 进入但在 flush 完成后才修改 MemTable，导致该数据未持久化。

**修复方案**：
1. `close()` 中先 flush 已有的 immutable，腾出 immutable 槽位
2. 再调用 `memTableManager.swapActive()` 将 current active 原子切换为 immutable（flushLock 保护）
3. 刷 immutable MemTable → SSTable
4. 再执行 WAL sync + close + levelManager.closeAll

**验收标准**：并发 add + close 重复 100 次不丢数据  
**Commits**: `d276a9a7` (fix) + `dd9c48d0` (test) + `bc4f64d8` (fix)  
**测试验证**: StoreTest(11) + StoreIntegrationTest(22) + ConcurrencyTest(5, 含testCloseDuringConcurrentWrites) + CompactionTest(6) 全部通过  
**压测结果**: 3 writer × 50ms = 1754 笔跨 close 边界的并发写入，reopen 后 100% 恢复

---

#### 1.2 【P0 数据安全】WAL 恢复后清理旧 WAL 文件 ✅

**文件**: `Store.cj`（Store.init）  
**类型**: 缺陷修复 | **预计**: 0.5 人天

**问题（B4）**：`Store.init()` 从旧 WAL 恢复数据后创建新 WAL，但未删除已恢复的旧 `.wal` 文件。旧文件永久残留。

**修复方案**：
1. `WALReader.recoverAll()` 完成后，扫描 `walDir` 删除所有已恢复的 `.wal` 文件
2. 或 WAL 构造函数中传递一个 `cleanupAfterRecovery` 参数，构造函数内清理

**验收标准**：恢复后 `walDir` 下只有当前 WAL 文件

---

#### 1.3 【P1 数据安全】Store.close byteCount 修复及时触发刷盘 ✅ 无需修复

**问题（Q4）**：~~WAL 恢复的数据写入 MemTable 后 `byteCount` 为 0，直到新写入才累加。~~

**实际情况**：`Store.init()` 中恢复循环调用 `memTableManager.getActive().add(key, entry)`，最终走 `MemTable.add()`（`MemTable.cj:31`），该方法内部执行 `byteCount.fetchAdd(...)`。所以 **byteCount 在恢复后即正确反映数据量**，无需修复。

---

#### 1.4 【P1 健壮性】并发读写测试 ✅

**文件**: `f_store/src/Concurrency_test.cj`  
**类型**: 测试补全 | **预计**: 1.5~2 人天

**状态**：`ConcurrencyTest` 已包含 5 个测试用例，全部通过：
- ✅ testMultiWriterConcurrentAdd — 4线程×100条不重叠key
- ✅ testReadWriteConcurrent — 读写并发，验证 value 单调不减
- ✅ testFlushAndWriteConcurrent — 大 value 触发 flush 期间并发读取
- ✅ testCompactionAndReadConcurrent — 多层 compaction 期间并发随机读
- ✅ testCloseDuringConcurrentWrites — close 期间持续写入（新增）

---

#### 1.5 【测试】WAL 损坏恢复测试 ✅

**文件**: `WALReader_test.cj`  
**类型**: 测试补全 | **预计**: 1 人天

**新增 3 个测试用例**：
- ✅ `walChecksumCorruptionSingleRecord` — 3 条记录，翻转第 2 条 key，恢复截断在第 1 条
- ✅ `walChecksumCorruptionConsecutive` — 5 条记录，翻转第 2、3 条 key，恢复截断在第 1 条
- ✅ `walRecoverEmptyAndCorruptedMixed` — 空 WAL + 正常 WAL(3条) + 损坏 WAL(第2条损坏)，正常文件全恢复，损坏文件截断

**验收标准**：损坏记录被安全截断，合法记录无丢失，无崩溃

---

#### 1.6 【测试】Compaction 多文件合并（>2 源）

**文件**: `Compaction_test.cj`、`SSTableMerger_test.cj`  
**类型**: 测试补全 | **预计**: 1 人天

**目标**：验证 L0 多 SSTable（4+）合并到 L1 的正确性

**实施步骤**：
1. 扩展 `SSTableMergerTest`：4 源归并有序性 + 去重 + tombstone
2. 扩展 `CompactionTest`：L0(4个文件) → L1(已有数据) 端到端

**验收标准**：4+ 源合并结果与逐个 2 源合并一致，端到端查询正确

---

### 第2阶段：代码修正 + 边界覆盖（预计 3~5 人天）

#### 2.1 【P1 边界】WAL 单文件轮转 + 多文件管理

**文件**: `WAL.cj`、`WALReader.cj`、`Store.cj`  
**类型**: 功能补全 | **预计**: 1 人天

**问题（B3）**：当前 WAL 使用单个文件永不分片轮转，长运行 Store 产生超大 WAL 文件。

**修复方案**：
1. 添加 WAL 文件大小跟踪，写入后检查是否超限（如 64MB）
2. 超限时关闭当前 WAL 文件，创建新 WAL 文件（文件名递增 sequence_start）
3. 对应 WALManager 管理多个 WAL 文件引用
4. 刷盘/compaction 完成后可删除对应的旧 WAL 文件

**验收标准**：持续写入 128MB 数据后产生至少 2 个 WAL 文件，恢复完整

---

#### 2.2 【P2 规范】Compaction 输出文件命名规范化

**文件**: `Compaction.cj`  
**类型**: 代码修正 | **预计**: 0.5 人天

**问题（B6）**：Compaction 输出文件名为 `L${nextLevel}_compact_${index}.sst`，不符合标准 `L{level}_{seqStart}_{seqEnd}.sst` 格式，`SSTable.parseFileName()` 解析失败。

**修复方案**：
1. 在 Compaction 输出中收集 sequenceStart/sequenceEnd
2. 文件名改为 `L${level}_${seqStart}_${seqEnd}.sst` 格式
3. SSTableMetadata 的 level 字段在 finishWrite 时设为正确的 level（当前硬编码为 0）

**验收标准**：Compaction 输出文件的 parseFileName 可解析，level 正确

---

#### 2.3 【P2 边界】MemTable 容量边界 + 极端大小测试

**文件**: `MemTableManager_test.cj`  
**类型**: 测试补全 | **预计**: 0.5 人天

**目标**：覆盖 MemTable 满触发 flush 和极端输入

**实施步骤**：
1. MemTable 持续 add 直到近似大小超限，验证 swap 后可继续写入
2. 空 key（0 字节）、空 value（0 字节）、大 value（64KB）的 add/get 正确性
3. SSTable 0 条 entry finish 不崩溃

**验收标准**：边界输入不崩溃、不产生损坏数据

---

#### 2.4 【P2 正确性】LevelManager L0 遍历优先查最新文件

**文件**: `LevelManager.cj`  
**类型**: 性能修复 | **预计**: 0.5 人天

**问题（B5 + 优化点1）**：L1+ 查询是线性扫描非二分（性能问题），L0 遍历未按 sequence 倒序（最新文件 last 最可能命中）。

**修复方案**：
1. L0 遍历改为从末尾开始反向遍历（最新数据优先匹配）
2. L1+ 保持线性扫描（文件数少时可接受）

**验收标准**：L0 大量文件时 get 延迟降低（最新数据多数在前几个文件找到）

---

#### 2.5 【P2 估算】LevelManager.shouldCompact 大小估算改用 fileSize

**文件**: `LevelManager.cj:200`  
**类型**: 代码修正 | **预计**: 0.5 人天

**问题（Q1）**：`entryCount * 100` 估算不准确。key/value 长度差异大时偏差大。

**修复方案**：
1. SSTableMetadata 增加 `fileSize` 字段
2. `finishWrite()` 时记录 `fileSize` 到 metadata
3. `shouldCompact()` 改用真实 `fileSize` 累加

**验收标准**：替换后各层大小估算与实际文件大小误差 <10%

---

### 第3阶段：性能优化 + 文档同步（预计 4~6 人天）

#### 3.1 【P2 性能】WAL 用户态缓冲写入

**文件**: `WAL.cj`  
**类型**: 性能优化 | **预计**: 1.5~2 人天

**目标**：将 WAL 写入 syscall 次数降低 10~100 倍，写吞吐提升 2~5x

**实施步骤**：
1. 新增 `buffer: Array<Byte>`（默认 64KB）和 `flushBuffer()` 方法
2. `append()` 将编码后 record 追加到 buffer；buffer 满时先 flush 再追加
3. `sync()` / `close()` 先 flushBuffer 再 fsync
4. 兼容性：确保 `WALReader.recover()` 不受影响

**验收标准**：相同负载下 write syscall 降低 ≥10x；恢复测试无回归

---

#### 3.2 【P2 性能】ByteArray 比较开销优化

**文件**: `ByteArray.cj`  
**类型**: 性能优化 | **预计**: 1 人天

**目标**：降低 MemTable 键比较 CPU 开销 10~20%

**实施步骤**：
1. `compare()` 中避免 `toUInt()` 转换开销，直接用 `Int64(a[i] - b[i])`
2. 对 ≥8 字节 key 使用逐 8 字节 UInt64 比较
3. 仓颉支持 `@Inline` 时添加

**验收标准**：`MemTableTest` 全部通过；10k 插入耗时降低 ≥10%

---

#### 3.3 【P3 性能】finishWrite 排序消除（条件优化）

**文件**: `SSTable.cj`（finishWrite）  
**类型**: 性能优化 | **预计**: 0.5 人天

**目标**：省去 MemTable flush 场景下的冗余排序

**实施步骤**：
1. 当前实现已不排序（MemTable iterator 天然有序），只需在 debug 模式下加断言验证
2. 确认 `Compactor` 输出（SSTableMerger）也天然有序

**验收标准**：FinishWrite 不做多余排序，存在断言

---

#### 3.4 【P3 性能】Compaction 读写锁

**文件**: `LevelManager.cj`  
**类型**: 性能优化 | **预计**: 1~1.5 人天

**目标**：消除 Compaction 期间对同层级 get 操作的阻塞

**实施步骤**：
1. 当前 `synchronized(levelLocks[level])` 保护 get 操作，与 compaction 互斥
2. 如果实测发现争用，改用读写锁

**验收标准**：compaction 期间 get 延迟增加 ≤5%

---

#### 3.5 【P3 文档】设计文档与实现同步

**文件**: `store.md`、`开发计划.md`  
**类型**: 文档修正 | **预计**: 0.5 人天

**需同步的偏差**：

| 文档描述 | 实现现状 | 文档应改为 |
|---------|---------|-----------|
| value_len = 0 表示 tombstone | value_len = -1 表示 tombstone | value_len = -1 表示 tombstone（>=0 为正常值含空数组） |
| createStoreStream 工厂函数 | 各构造器内联 @When | 移除createStoreStream描述，更新为内联模式 |
| SSTable magic = 0x4C534D54 | 0x53545354 ("STST") | 更新为 0x53545354 |
| WAL 多文件轮转 | 单文件（待实现B3后更新） | 按 B3 修复后同步 |
| close 顺序：swap→flush→WAL→SSTable→Compaction | stop→flush→WAL→SSTable | 同步为正确实现 |

---

### 改进计划总览

| 阶段 | 优先级 | 任务 | 类型 | 预计人天 |
|------|--------|------|------|----------|
| 1 | P0 | Store.close 数据丢失窗口修复 ✅ | 缺陷 | 0.5 |
| 1 | P0 | WAL 恢复后清理旧文件 ✅ | 缺陷 | 0.5 |
| 1 | P1 | byteCount 恢复后重建 ✅（无需修复） | 缺陷 | — |
| 1 | 高 | 并发读写测试 ✅ | 测试 | 1.5~2 |
| 1 | 高 | WAL 损坏恢复测试 ✅ | 测试 | 1 |
| 1 | 高 | Compaction 多文件合并测试 | 测试 | 1 |
| 2 | P1 | WAL 单文件轮转 | 功能 | 1 |
| 2 | P2 | Compaction 文件名规范 | 代码修正 | 0.5 |
| 2 | P2 | MemTable 容量边界 + 极端大小测试 | 测试 | 0.5 |
| 2 | P2 | L0 遍历逆序优化 | 性能 | 0.5 |
| 2 | P2 | shouldCompact 大小估算改用 fileSize | 代码修正 | 0.5 |
| 3 | P2 | WAL 用户态缓冲写入 | 性能 | 1.5~2 |
| 3 | P2 | ByteArray 比较开销优化 | 性能 | 1 |
| 3 | P3 | finishWrite 排序断言 | 性能 | 0.5 |
| 3 | P3 | Compaction 读写锁 | 性能 | 1~1.5 |
| 3 | P3 | 设计文档同步 | 文档 | 0.5 |

**总计**：约 11~14 人天，分 3 个阶段迭代交付

