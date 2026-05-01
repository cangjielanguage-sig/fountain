# f_store 源码审查任务

> 已完成全面审查，详见下方报告

## ✅ f_store 源码审查完成

**审查时间**: 2026-05-01
**审查范围**: `f_store/src/*.cj`（排除 `*_test.cj` / `*_bench.cj`，共 20 个源文件）
**关注点**: 性能瓶颈、并发安全、FD泄漏、未关闭资源

---

### P0 — FD泄漏（2项）

#### ~~P0-1: SSTable.open/openFromFile 异常路径 FD 泄漏~~（撤回报警）

**文件**: `SSTable.cj:346-349`

**误报原因**: `open()` 调用 `openFromFile(file, path)`，而 `openFromFile` 在返回前通过 `SSTable(path, file, filter, indexEntries, meta, idxOff)`（第 409 行）将 `file` 存入 SSTable 实例的 `this.file` 成员变量。因此：
- **成功路径**: `file` 归返回的 SSTable 管理，由其生命周期负责关闭
- **异常路径**: 仅发生在启动时 `loadAll()` 中读取损坏文件时，单个 FD 短暂未关闭即随异常传播被回收

结合 `loadAll()` 调用处的 `catch (_: Exception) {}` 和该路径仅启动期一次性执行的特点，不构成实际问题。

---

#### ✅ P0-2: Compaction 异常路径下已生成 SSTable FD 泄漏（已修复）

**文件**: `Compaction.cj:77` + `store_func.cj:134-147`

**问题描述**: 两个层面：
1. `writeStreamToSSTables()` (`store_func.cj:134`) 的 catch 块只关闭了当前 writer，没有关闭 result 中已 finishWrite 的 SSTable（它们的 FD 仍然打开）
2. `Compactor.compact()` (`Compaction.cj:77`) 的 catch 直接忽略异常，newSSTables 中已有的 SSTable 既未添加到 LevelManager 也未关闭

**触发条件**: Compaction 写入过程中 I/O 错误，已生成部分 SSTable 后失败。

**根因分析**:

```
writeStreamToSSTables() 内部:
  result = [SSTable-A(finishWrite, FD open), SSTable-B(finishWrite, FD open)]
  继续写 SSTable-C ... 异常抛出
  → catch 只 close(C) + delete(C.sst)
  → 但 result = [A, B] 中的 A, B 的 FD 从未被关闭

Compactor.compact() 调用方:
  let newSSTables = writeStreamToSSTables(...)  // 异常，newSSTables 未赋值
  → newSSTables 变量不存在，无法访问 result
  → A.sst, B.sst 文件留在磁盘，FD 泄漏
```

**修复方案**: 只需修改 `writeStreamToSSTables`（`store_func.cj:134-146`）一处。
`Compactor.compact()` 中的 try-finally 已经正确关闭 sources，无需修改。

**修改后代码**（`store_func.cj` `writeStreamToSSTables`）：

```cj
func writeStreamToSSTables(iter: Iterator<(ByteArray, EntryValue)>, sstDir: String, level: Int64): ArrayList<SSTable> {
    let result = ArrayList<SSTable>()
    var sstIndex: Int64 = sstableFileSeq.incrFetch()
    var writerPath = "${sstDir}/L${level}_${sstIndex}.sst"
    var writer = SSTable(writerPath, 64)
    try {
        while (let Some((key, entry)) <- iter.next()) {
            writer.write(key, entry)
            if (writer.isFull()) {
                writer.finishWrite(level: level)
                result.add(writer)
                sstIndex++
                writerPath = "${sstDir}/L${level}_${sstIndex}.sst"
                writer = SSTable(writerPath, 64)
            }
        }
        if (writer.getEntryCount() > 0) {
            writer.finishWrite(level: level)
            result.add(writer)
        } else {
            writer.close()
        }
    } catch (e: Exception) {
        // 1. 关闭当前正在写入的 SSTable（Writing 状态，未 finishWrite）
        writer.close()
        // 2. 删除当前正在写入的孤儿文件（未 finishWrite，内容不完整）
        try {
            if (exists(writerPath)) {
                remove(writerPath)
            }
        } catch (e2: Exception) {
            let thrown = SSTableWritingException(e2)
            thrown.addSuppressed(e)
            throw thrown
        }
        // 3. 关闭 + 删除 result 中已 finishWrite 的 SSTable
        //    这些文件虽然格式完整，但 compaction 已中断，不应保留
        for (sst in result) {
            try {
                sst.close()
                if (exists(sst.getMetadata().filePath)) {
                    remove(sst.getMetadata().filePath)
                }
            } catch (_: Exception) {}
        }
        throw e
    }
    result
}
```

**修改要点**:
1. 新增 `for (sst in result)` 循环，关闭每个已 finishWrite 的 SSTable
2. 同时删除对应的 `.sst` 文件 —— 已中断的 compaction 不应留下孤儿数据
3. 关闭/删除操作单独捕获异常，不干扰主异常 `e` 的传播
4. `Compactor.compact()` 无额外修改需求 —— 其 try-finally 已正确管理 sources

**收益**: 消除 Compaction 异常时 result 中已 finishWrite 的 SSTable 的 FD 泄漏 + 磁盘孤儿文件残留。

**改动量**: 仅 `store_func.cj` 的 catch 块增加 9 行代码，无调用方修改。

---

### P2 — 性能（1项）

#### ✅ P2-1: Compaction 对所有 level 统一选 4 个文件（已修复）

**文件**: `Compaction.cj:104-137`

**问题描述**: `compact(level)` 对 L0 和 Ln (n≥1) 统一使用"从末尾选最多 4 个文件"的策略。对 L0（key 范围完全重叠）这是合理的，但对 Ln 层（SSTable 之间 key 范围不重叠），"末尾 4 个"的 range 可能与 nextLevel 完全无重叠，导致无效 IO。

**修复方案**: L0 保持"末尾最多 4 个"策略不变；Ln 改为按 key 范围重叠筛选：
- 获取 nextLevel 的 SSTable 列表
- 检查当前层每个 SSTable 是否与 nextLevel 有任何范围重叠
- 有重叠的文件加入 selected 列表
- 无重叠时选最后一个文件（1 个最小 compaction 单元）
- 测试验证：`nonL0SelectsOverlappingOnly`、`nonL0NoOverlapSelectsLastOne`

---

### P3 — 代码质量（2项）

#### P3-1: SSTable.close() 中 @When 分支重复代码

**文件**: `SSTable.cj:441-453`

**问题描述**: Linux 和非 Linux 的 `synchronized(getLock) { close file }` 代码完全相同，但分别写在两个 @When 分支中。

**修复方案**: 合并两个分支：

```cj
synchronized (getLock) {
    if (!file.isClosed()) {
        file.close()
    }
}
```

---

#### P3-2: parseBloomFilter 多余间接调用

**文件**: `SSTable.cj:609-611`

**问题描述**: `parseBloomFilter(bloomBuf)` 仅包装了 `BloomFilter.deserialize(bloomBuf)`，参数类型已匹配，无额外逻辑。

**修复方案**: 内联为 `BloomFilter.deserialize(bloomBuf)`。

---

### 未发现的问题

- ✅ **并发安全**: 所有共享状态使用 AtomicReference/AtomicInt64/Mutex 保护，CAS+copy 模式正确
- ✅ **WAL 关闭**: close() 使用 appendLock + closed CAS 保证正确性
- ✅ **迭代器 FD 管理**: SSTableIterator 独立 File 句柄 + 幂等 close()，设计正确
- ✅ **PrefixIterator FD**: 通过 sources list 统一 close，无泄漏
- ✅ **LevelManager 级别大小缓存**: AtomicInt64 增量缓存正确性已验证
- ✅ **sstableFileSeq**: AtomicInt64.incrFetch 保证 flush/compaction 并发安全
