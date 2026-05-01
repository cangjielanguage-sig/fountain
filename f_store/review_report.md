# f_store 代码审查报告

**范围**: `f_store/src/*.cj` (20 个生产文件 + 15 个测试文件跳过)
**审查目标**: 性能瓶颈、并发安全问题、文件描述符泄漏、未关闭文件
**审查日期**: 2026-05-01
**分支**: review/f_store_src

---

## P1 — 需要立即修复

### P1.1 Compaction.cj:135-142 sources 构建阶段不在 try 保护内 → FD 泄漏

**位置**: `Compaction.cj:135-141`

```cj
// 4. 构建多路归并迭代器
let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
for (sst in selectedSSTables) {
    sources.add(PeekableIterator(sst.iterator()))  // ← 可能抛出异常
}
for (sst in overlappingSSTables) {
    sources.add(PeekableIterator(sst.iterator()))  // ← 可能抛出异常
}

try {  // ← try 从这开始，之前的 sources 不受保护
```

**问题**: 第135-141行创建的 `PeekableIterator` 包装了 `SSTableIterator`（包含独立 File 句柄）。如果 `sst.iterator()` 抛出 `StoreClosedException` 或 `File` 打开失败，已创建的迭代器对应的 FD 永远不会被关闭。finally 块（第172-180行）只在 try 范围内的 sources 被关闭。

**触发条件**: compaction 期间有 SSTable 被并发关闭（虽然罕见，但可能）。
**修复**: 将 try-finally 提前覆盖 sources 构建阶段。

### P1.2 Compaction.cj:107 L0 全部返回 → 不必要的大列表

**位置**: `Compaction.cj:100,107`

```cj
let levelSSTables = levelManager.getSSTablesForCompaction(level)
// ...
let pickCount = if (levelSSTables.size > 4) { 4 } else { levelSSTables.size }
```

`getSSTablesForCompaction(level)` 返回 L0 层的**全部**文件（`LevelManager.cj:190-200`）。当 L0 文件很多时（例如 100 个），它复制整个列表，但 compaction 仅使用最后 4 个。这是不必要的 O(n) 复制。

**修复**: 在 `LevelManager` 中添加 `getSSTablesForCompactionSuffix(level, count)` 方法，只返回最后 count 个文件。

---

## P2 — 潜在问题（无需立即修复，但建议关注）

### P2.1 Store.init() 双重遍历恢复数据

**位置**: `Store.cj:61-79`

```cj
// 第61-64行：第1次遍历 — 添加数据
let iter = recovered.iterator()
while (let Some((key, entry)) <- iter.next()) {
    memTableManager.getActive().add(key, entry)
}
// 第74-79行：第2次遍历 — 找最大 sequence
let recoveryIter = recovered.iterator()
while (let Some((_, entry)) <- recoveryIter.next()) {
    if (entry.sequence > startSeq) { startSeq = entry.sequence }
}
```

**问题**: WAL 恢复的数据被遍历两次。每次迭代涉及跳表遍历，对大数据量恢复（数百万 key）有明显的性能浪费。

**修复**: 合并为单次遍历，在添加时记录最大 sequence。

### P2.2 store_func.cj:108 SSTableWriter 异常时 writer 关闭但 SSTable(继承 Resource) 可能泄漏

**位置**: `store_func.cj:117,137`

`writeStreamToSSTables()` 的异常处理和正常路径都在 `writer` 上操作。但如果 `new SSTable(writerPath, 64)` 第2次创建（第127行，新文件）成功，但 `writer.write()` 或 `writer.isFull()` 抛出异常，旧的 `writer`（第124行已 finishWrite 并加入 result）已经正确处理。问题是第137行 `writer.close()` 关闭的是当前 writer，但 `result` 中的已 finishWrite 的 SSTable 文件句柄仍然打开且需要被调用方（Compaction 或 flushMemTable）关闭。

**验证**: 调用方 `Compaction.compact()` 在 `writeStreamToSSTables` 返回后，将 newSSTables 直接 `levelManager.addSSTable(nextLevel, sst)`，不需要额外关闭。`flushMemTable` 返回后由 `Store.close()` 或 `maybeFlush()` 的调用者管理。所以已 finishWrite 的 SSTable 句柄最终由 `LevelManager.closeAll()` 关闭。

**结论**: 不是泄漏，流程正确。

### P2.3 SSTable.parseFileName() 与实际文件名格式不一致

**位置**: `SSTable.cj:440-465`

`parseFileName()` 注释和代码期望 `L{level}_{seqStart}_{seqEnd}.sst`（3 段），但实际生成的文件名是 `L${level}_${sstIndex}.sst`（2 段，`store_func.cj:117`）。这意味着 `parseFileName()` 如果被调用，会对所有文件返回 `None`。

**建议**: 
- `parseFileName()` 要么改为匹配 2 段格式，要么删除（如果未使用）。
- 确认该函数无调用者后移除。

### P2.4 SSTableIterator.loadBlock() Linux 上 pread 后未检查 isClosed

**位置**: `SSTableIterator.cj:216-233`

```cj
@When[os == "Linux"]
let readOk = {=>
    let bufHdl = unsafe { acquireArrayRawData<Byte>(blockData) }
    try {
        positionedRead(fd, bufHdl.pointer, blockSize, blockStart)
    } finally {
        unsafe { releaseArrayRawData(bufHdl) }
    }
}()
```

`loadBlock()` 使用独立 File 句柄的 fd 做 pread，但 SSTable.close() 不影响此 fd（迭代器独立打开文件）。同时迭代器使用期间 compaction 只是读取数据（通过其他迭代器），不会删除文件（unlink 后在仍有 open FD 时数据可达）。因此**实际无风险**，但建议补充注释说明设计依据。

---

## P3 — 优化建议

### P3.1 LevelManager.getInLevel() L0 搜索未利用 Bloom Filter 跳过

**位置**: `LevelManager.cj:88-104`

L0 遍历时对每个 SSTable 调用 `sst.get(key)`（内部含 Bloom Filter 检查）。但 Bloom Filter 的否定能力在跳表/内存中已经能快速判断。可以考虑在 LevelManager 层缓存 Bloom Filter 的否定结果，减少 SSTable.get() 调用。

**收益**: 低 — 取决于 L0 文件数量和 Bloom Filter 的否定率。

### P3.2 writeStreamToSSTables() 创建新 writer 前检查目录

**位置**: `store_func.cj:111-115`

每次调用都检查 `exists(sstDir)` + 可能创建目录。此检查应该仅在首次需要时进行（例如在 `sstDir` 已确认存在时跳过）。

**收益**: 极低 — 每次 flush/compaction 调用仅一次。

### P3.3 WAL.append() atomic size check 允许文件轻微超限

**位置**: `WAL.cj:70-73`

```cj
let prevSize = currentFileSize.fetchAdd(Int64(encoded.size))
if (prevSize >= maxFileSize) {
    rotate()
}
```

`prevSize` 是添加当前记录前的文件大小。如果 `prevSize = 64MB - 1` 且记录较大，文件实际大小会超过 `maxFileSize`。下次 append 才会触发 rotate。**实际影响可忽略**。

---

## 并发安全总结

| 模块 | 设计 | 评价 |
|------|------|------|
| Store | AtomicBool(closed) + WAL appendLock | √ 正确 |
| MemTableManager | AtomicReference<MemTablePair> + CAS | √ 正确 |
| LevelManager | AtomicReference<ArrayList> + copy-CAS | √ 正确 |
| SSTable.get() | synchronized(getLock) + 双层 guardReadable | √ 正确 |
| SSTable.close() | AtomicBool CAS + 锁内关闭文件 | √ 正确 |
| WAL.append() | appendLock + 重检 closed | √ 正确 |
| WAL.rotate() | appendLock 内 + oldFilesLock | √ 正确 |
| Compaction | **sources 构建无异常保护** → **P1.1** | ✗ 需修复 |
| SSTableIterator | 独立 File + fd，不与 SSTable.close 竞争 | √ 正确 |

## FD 管理总结

| 路径 | FD 来源 | 关闭方式 | 状态 |
|------|---------|----------|------|
| SSTable（写入模式） | init 中 file = File(path, OpenMode.ReadWrite) | close() 中关闭 | √ |
| SSTable（openFromFile） | 传入的 File | close() 中关闭 | √ |
| SSTable.iterator() | 内部新开 File(path, OpenMode.Read) | SSTableIterator.close/setDone | √ |
| SSTableMerger | 包装传入的 PeekableIterator | 调用方（Compaction finally） | √ |
| Compaction sources | PeekableIterator(SSTableIterator) | finally 块 | ✗ P1.1 |
| WALReader.readAll() | File(path, OpenMode.Read) | try-finally 中 close | √ |
| PrefixIterator | 外部传入的 PeekableIterator | close() 中排空所有源 | √ |
