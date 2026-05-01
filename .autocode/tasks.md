# f_store 代码审查 — 优化计划

> 来源：全面审查 f_store/src/*.cj 生产代码
> 基于现有修复（f_store/doc/优化方案.md 中 P0-P3 全部修复完成）后的最新审查发现

## P0（正确性缺陷 — 必修）

### P0-1: SSTable.openFromFile 重启后所有文件落入 L0 ✅
- **文件**: SSTable.cj:398
- **问题**: openFromFile 创建 metadata 时硬编码 `level: 0`，level 未持久化到文件格式（footer 无 level 字段）
- **影响**: 重启后所有 SSTable 进入 L0，L0 膨胀，Compaction 需重推，tombstone 移除状态丢失
- **修复**: 从文件名 `L{level}_{sstIndex}.sst` 解析 level，替代硬编码 0
- **测试**: `LevelManagerTest.levelManagerLoadRestoresCorrectLevels` / `SSTableTest.sstableOpenFromFileParsesLevelFromName` / `SSTableTest.sstableParseHelpersWorkCorrectly`

### P0-2: sstableFileSeq 重启后从 0 开始 ✅
- **文件**: store_func.cj:105
- **问题**: 全局计数器 `sstableFileSeq = AtomicInt64(0)` 未持久化。重启后从 0 开始计数，多次操作后序号达到磁盘已有文件名时产生覆盖
- **影响**: 覆盖已有 SSTable 文件 → 旧数据静默丢失
- **修复**: loadExisting 完成后设置 sstableFileSeq = maxIndex + 1
- **测试**: `LevelManagerTest.levelManagerLoadUpdatesSSTableFileSeq` / `LevelManagerTest.levelManagerLoadEmptyDirDoesNotChangeSSTableFileSeq`

## P1（重要缺陷 — 建议修复）

### P1-1: Compactor 线程不可等待 — close 与 compaction 竞态 ✅
- **文件**: Compaction.cj:40-43 + Store.cj:227
- **问题**: spawn 返回值丢弃，`stop()` 仅设 stopSignal。`Store.close()` 中 `closeAll()` 执行后 compactor 仍可能向 LevelManager 添加 SSTable
- **影响**: 新 SSTable File 句柄泄漏；并发访问可能 StoreClosedException
- **修复**: 保存 Future，stop() 调用 future.get() 等待线程结束

### P1-2: WAL.sync() 在 appendLock 外执行 ✅
- **文件**: WAL.cj:76
- **问题**: `append()` 退出 `synchronized(appendLock)` 后执行 `file.flush()`，不受 appendLock 保护。与 close() 间存在竞态窗口
- **影响**: 极小概率对已关闭文件调用 flush() → 未捕获异常 → 线程崩溃
- **修复**: sync() 移入 appendLock 内执行，确保与 close 互斥

### P1-3: addWithExpire 旧值过期检查使用 fresh now() ✅
- **文件**: Store.cj:266
- **问题**: `add()` 返回旧值时重新调用 `DateTime.now()`，语义上 `add()` 应返回添加时的旧值而非"添加完成时的旧值"
- **影响**: 添加时旧值未过期，完成时已过期 → 返回 None，违反语义
- **修复**: 删除此过期检查，直接返回 oldEntry.value
- **测试**: `StoreTest.testAddOverwriteExpiredKeyReturnsOldValue`

## P2（中等 — 可选）

### P2-1: Compaction 关闭/删除顺序风险 ✅
- **文件**: Compaction.cj:146-165
- **问题**: 新 SSTable 加入 LevelManager 后，并发 get() 的快照引用旧 SSTable 的同时文件被删除。pread 失败 → guardNotClosed() 抛异常 或 scanBuffer 无帧校验静默返回 None
- **修复**: scanBuffer 增加帧校验（keyLen ≥0、valueLen ≥ -1、sequence ≥ 0）
- **版本**: 此前 P1 已将 guardNotClosed() 改为返回 None，配合帧校验提供双重防御
- **测试**: `SSTableTest.sstableScanBufferDetectsCorruptedData` / `SSTableTest.sstableScanBufferRejectsInvalidValueLen`

### P2-2: Compaction L0 全选 ✅
- **文件**: Compaction.cj:97-98
- **问题**: L0 compaction 选择全部文件。P0-1 触发后 L0 可能数十个文件，合并瞬时大量 FD 占用
- **修复**: L0/Ln 统一从末尾选最多 4 个（新文件优先合并）
- **测试**: `CompactionTest.compactorL0SelectsAtMostFour`

### P2-3: PrefixIterator.close() 排空开销 ✅
- **文件**: PrefixIterator.cj:106-108 + f_base/src/Peekable.cj
- **问题**: close() 通过 `while (src.next().isSome()) {}` 排空所有源，对 64MB SSTable 产生 ~100ms 延迟
- **修复**: PeekableIterator 实现 Resource，PrefixIterator.close() 直接调 src.close() 跳过排空
- **测试**: `PrefixIteratorTest.testPrefixIteratorCloseDirectly` / `PrefixIteratorTest.testPeekableIteratorClosesUnderlyingResource`

### P2-4: SSTableIterator.loadBlock() 忽略 pread 失败 — 静默返回全零数据 ✅
- **文件**: SSTableIterator.cj:202-226
- **问题**: loadBlock() 丢弃 positionedRead 返回值，pread 失败时 blockData 全零。next() 与 scanBuffer 缺少帧校验，全零数据被解析为有效条目输出
- **影响**: 并发 compaction 关闭 SSTable 后，持有快照的迭代器输出垃圾数据（SSTableMerger 中损坏输出，PrefixIterator 中浪费 CPU）
- **修复**: loadBlock() 检查 pread 返回值，失败调用 setDone()；next()/skipBefore() 增加 keyLen≥0/valueLen≥-1/seq≥0 帧校验
- **测试**: `SSTableTest.sstableIteratorStopsOnCorruptedBlock` / `SSTableTest.sstableIteratorRejectsInvalidValueLen`
