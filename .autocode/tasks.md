# f_store 第十六轮代码审查报告

> 审查日期：2026-05-02
> 范围：全面静态审查 f_store/src/*.cj 生产代码 + 测试文件（20+源文件）
> 前轮已记录问题见 `f_store/doc/优化方案.md`

---

## P1 — writeStreamToSSTables 异常路径步骤2 throw 跳过步骤3 cleanup（修复不完整）

- **位置**: `store_func.cj:143-145`
- **问题**: `writeStreamToSSTables()` catch 块中步骤 2（删除当前 writer 孤儿文件）失败时：
  ```cj
  } catch (e2: Exception) {
      let thrown = SSTableWritingException(e2)
      thrown.addSuppressed(e)
      throw thrown     // ← 提前 return，步骤 3 被跳过！
  }
  // 步骤 3（for sst in result { close + remove }）不会执行
  ```
  依然会提前 throw，跳过步骤 3 的 result 清理（关闭已 finishWrite 的 SSTable + 删除对应 .sst 文件）。
- **根因**: `980bef52` 修复仅将步骤 3 的 `catch (_: Exception) {}` 改为 `catch (ee: Exception) { ex.addSuppressed(ee) }`，并添加了 `let ex = SSTableWritingException(e)` 作为主异常。但步骤 2 仍然保持"创建新异常 + throw"模式，未改为"添加到主异常 + 继续"。
- **预期修复**: 步骤 2 与步骤 3 一致，用 `ex.addSuppressed(e2)` 替代 `throw thrown`：
  ```cj
  } catch (e2: Exception) {
      ex.addSuppressed(e2)   // 附加到主异常，不提前 throw
  }
  // 继续执行步骤 3
  ```
- **触发条件**: writer.write()抛异常 → 步骤 1 writer.close()成功 → 步骤 2 remove(writerPath)抛异常（权限/IO错误、并发删除等）
- **实施难度**: 低（2 行修改）

---

## P2 — LevelManager.getOverlappingSSTables Ln 路径缺少 StoreClosedException 保护

- **位置**: `LevelManager.cj:232-239`
- **问题**: `getOverlappingSSTables()` Ln 分支遍历 SSTable 时调用 `sst.getMetadata()`，未包裹 try-catch。与 `getInLevel()`(line 87-130) 不同，后者 Ln 分支使用 try-catch 捕获 `StoreClosedException`。
- **触发条件**: 用户线程调用 `Store.prefix()` → `LevelManager.getSSTablesInRange()` → `getOverlappingSSTables()`。Compaction 线程在 snapshot load() 后、`getMetadata()` 前关闭了 SSTable：
  1. Thread A (prefix): `levels[level].load()` → 得到快照 [A, B, C]
  2. Thread B (Compaction): `removeSSTables(level, [B])` → B.close()
  3. Thread A: B.getMetadata() → guardReadable() → throw StoreClosedException
- **影响**: prefix 操作因 Compaction 竞态而抛出 StoreClosedException，但 Store 本身未关闭。用户收到误报。
- **预期修复**: 为 `sst.getMetadata()` 调用加上 try-catch (`catch (_: StoreClosedException) { continue }`)
- **实施难度**: 低（+4 行）

---

## P3 — ConcurrencyTest.testFlushAndWriteConcurrent reader 死错误变量

- **位置**: `Concurrency_test.cj:156-168`
- **问题**: Reader 线程声明 `var errors: Int64 = 0`，但循环体只执行 `readCount++` 和 `sleep`，从未对 errors 赋非零值。最后 `@Expect(errors == 0)` 恒为真，无测试价值。
- **预期修复**: 删除 `errors` 变量及断言，或补全实际错误检查逻辑。
- **实施难度**: 低

---

## 新增问题小结

| 等级 | 问题 | 位置 |
|------|------|------|
| P1 | writeStreamToSSTables 步骤2跳过步骤3 cleanup | store_func.cj:143-145 |
| P2 | getOverlappingSSTables Ln 缺 StoreClosedException 保护 | LevelManager.cj:232 |
| P3 | testFlushAndWriteConcurrent reader 死 error 变量 | Concurrency_test.cj:156 |

---

## 已确认无问题（本轮审查）

- **Store.close() 重复 flush 路径**: close() 先 flush immutable → swapActive → flush new immutable → wal sync/close → levelManager.closeAll。swapActive 可重入，无竞态。
- **WAL.rotate() 在 appendLock 内调 sync()**: 仓颉 Mutex/synchronized 可重入，不会死锁。
- **Compaction Ln 快照过期**: Compactor 单线程执行 getSSTablesForCompaction → compact → removeSSTables，快照一致性由线程内顺序保证。
- **LevelManager.loadExisting() 直接 add 而非 CAS**: init 时串行执行，无并发，可接受。
- **SSTable.write 有序性断言**: finishWrite 消排序后 write 路径检查 `key >= lastKey`，正确性有保证。
- **PrefixIterator 实时 now()**: vDSO ~300ns/次，外部驱动增量遍历不可缓存，设计正确。
