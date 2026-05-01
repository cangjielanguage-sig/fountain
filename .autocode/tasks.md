# f_store 源码全面审查任务

> 2026-05-01 第二轮审查完成，发现 1×P1 + 1×P2 + 1×P3

**审查范围**: `f_store/src/*.cj`（排除 `*_test.cj` / `*_bench.cj`，共 20 个源文件）
**关注点**: 性能瓶颈、并发安全、FD泄漏、未关闭资源

---

## P1: LevelManager 过期快照导致虚假 StoreClosedException

### 位置
`LevelManager.cj:87-130`（`getInLevel` 方法）

### 问题描述

`LevelManager.getInLevel()` 先从 `AtomicReference` 原子加载 SSTable 列表快照，然后遍历快照并调用 `sst.get(key)`。若 **Compaction 线程在快照加载后** 关闭了其中某个 SSTable，会发生以下时序：

```
Reader 线程                         Compactor 线程
─────────────────────────────────────────────────────
levels[level].load() → 快照 [A, B, C]
                                    removeSSTables(level, [B])
                                    B.close() → CAS closed=true
                                    → state.store(CLOSED)
                                    → synchronized(getLock)
                                    → file.close()
                                    → 释放 getLock
for (sst in [A, B, C]):
  sst.get(key)  // sst = B
  → synchronized(getLock)
  → guardReadable()
  → state == CLOSED → throw StoreClosedException!
```

**根因**: 锁无关数据结构（AtomicReference copy+CAS）天然允许读取者持有过期快照。当快照中的元素被 Compaction 删除并关闭后，访问该元素会触发 `guardReadable()` 抛出 `StoreClosedException`。该异常是 SSTable 级别的关闭信号，但 Store 本身未关闭，导致**误报**。

**触发条件**: `Store.get()` 并发于 `Compactor.compact()`，Reader 在 Compaction 替换列表后仍持有旧快照。并发越高、Compaction 越频繁，概率越大。

**影响**: 正常 `Store.get()` 调用抛出 `StoreClosedException`，即使 Store 正常运行。这会导致上层应用认为 Store 已损坏或已关闭，可能触发错误的重连或重启逻辑。

### 解决方案

在 `LevelManager.getInLevel()` 中捕获 `StoreClosedException`，跳过该 SSTable 继续向后查找：

**修改 `LevelManager.cj`**：

L0 循环（约第 104 行）：
```cj
// 改前
let entry = sst.get(key)
if (let Some(e) <- entry) {
    return checkExpiry(e, now)
}

// 改后
try {
    let entry = sst.get(key)
    if (let Some(e) <- entry) {
        return checkExpiry(e, now)
    }
} catch (_: StoreClosedException) {}
```

Ln 循环（约第 121 行）：
```cj
// 改前
let entry = sst.get(key)
if (entry.isSome()) {
    if (let Some(e) <- entry) {
        return checkExpiry(e, now)
    }
}

// 改后
try {
    let entry = sst.get(key)
    if (entry.isSome()) {
        if (let Some(e) <- entry) {
            return checkExpiry(e, now)
        }
    }
} catch (_: StoreClosedException) {}
```

**安全分析**: 在 `LevelManager.getInLevel()` 上下文中，`StoreClosedException` 只能来自 SSTable.get() 内部 `guardReadable()` 的关闭检测，因为调用链 `Store.get()` → `LevelManager.get()` 在进入前已通过 `guardOpen()` 确认 Store 未关闭。

**改动量**: 仅 `LevelManager.cj` 两处加 try-catch（+4 行），无跨文件修改。

---

## P2: writeStreamToSSTables 异常路径中 remove 失败绕过 result 清理

### 位置
`store_func.cj:134-161`

### 问题描述

`writeStreamToSSTables()` 的 catch 块有三步清理逻辑：
1. 关闭当前 writer（Writing 状态）
2. 删除当前 writer 的孤儿文件
3. 关闭 + 删除 result 中已 `finishWrite` 的 SSTable

当前代码在步骤 2 失败时（创建 `SSTableWritingException` 并立即 throw）跳过了步骤 3：

```cj
} catch (e: Exception) {
    let ex = SSTableWritingException(e)
    writer.close()                                    // 步骤 1 ✓
    try {
        if (exists(writerPath)) {
            remove(writerPath)                        // 步骤 2
        }
    } catch (e2: Exception) {
        let thrown = SSTableWritingException(e2)
        thrown.addSuppressed(e)
        throw thrown  // ← 提前 return，步骤 3 被跳过！
    }
    for (sst in result) { ... }                       // 步骤 3（不会执行）
    throw ex  // ← 不会执行
}
```

**触发条件**: Compaction 写入过程中 I/O 错误，且删除当前孤儿文件也失败（罕见——权限错误、磁盘满、并发删除等）

**影响**: result 中已 `finishWrite` 的 SSTable 的 FD 泄漏 + `.sst` 文件残留磁盘。后续若再次发生 Compaction 读到这些文件可能产生错误数据。

### 解决方案

将步骤 2 的异常附加到主异常，不提前 throw，确保步骤 3 始终执行：

```cj
} catch (e: Exception) {
    let ex = SSTableWritingException(e)
    writer.close()
    try {
        if (exists(writerPath)) {
            remove(writerPath)
        }
    } catch (e2: Exception) {
        ex.addSuppressed(e2)  // 附加而非提前 throw
    }
    for (sst in result) {
        try {
            sst.close()
            if (exists(sst.getMetadata().filePath)) {
                remove(sst.getMetadata().filePath)
            }
        } catch (ee: Exception) {
            ex.addSuppressed(ee)
        }
    }
    throw ex
}
```

**改动量**: `store_func.cj:143-147` 将 `thrown` + `throw thrown` 替换为 `ex.addSuppressed(e2)`

---

## P3-1: WAL.sync() 与 WAL.close() 竞态导致 file.flush() 在已关闭文件上调用

### 位置
`WAL.cj:83-87`

### 问题描述

`WAL.sync()` 没有使用 `appendLock` 保护，与 `WAL.close()` 存在竞态：

```
Store.syncWAL()                Store.close()
─────────────────              ─────────────────
guardOpen() → closed=false
                               closed.CAS(true) → true
                               WAL.close()
                               → WAL.closed.CAS(true)
                               → synchronized(appendLock)
                               → file.flush()
                               → file.close()
                               → 释放 appendLock
WAL.sync()
!WAL.closed.load() → true
file.flush() → 文件已关闭 → 异常！
```

**触发条件**: `syncWAL()` 刚好在 `close()` 的 Store-level closed 标记前通过 `guardOpen()`，随后 WAL 被关闭。

**影响**: 抛出异常（无数据丢失——close() 已 flush），客户端收到虚假异常，可能触发不必要的错误处理逻辑。

### 解决方案

`synchronized (appendLock)` 保护 sync()，确保与 close() 互斥：

```cj
func sync(): Unit {
    synchronized (appendLock) {
        if (!closed.load()) {
            file.flush()
        }
    }
}
```

**改动量**: `WAL.cj:83-87` 加 synchronized 包裹，+2 行

---

## ~~P3-2: MemTableManager.swapActive() 死代码~~ （误报，已撤回）

### 位置
`MemTableManager.cj:53`

### 误报原因

仓颉中 `while(true)` 作为函数的最后表达式时，函数体会被推断为 `Unit` 类型。若函数显式声明了返回类型 `?MemTable`，编译报错。若未显式声明返回类型则推断为 `Unit`，与 `while(true)` 内部的 `return Some/None` 冲突。

因此末尾的 `None` 不是死代码，而是**仓颉编译器类型推断所需的占位表达式**，保持函数返回类型正确推断为 `?MemTable`。

---

## 未发现的问题（已确认无隐患）

- ✅ **SSTable.openFromFile 启动路径 FD 短暂泄漏**: 仅 `Store.init()` → `loadAll()` 路径，catch 吞异常后 FD 随进程生命周期管理。前轮审查已确认可接受。
- ✅ **SSTable.iterator()/tailer() FD 管理**: 每次调用打开独立 File 句柄，SSTableIterator 实现 Resource，耗尽或 try-with-resource 自动关闭。
- ✅ **Compaction sources finally 关闭**: try-finally 块在所有路径（含异常退出）正确关闭所有 PeekableIterator → SSTableIterator → File 句柄。PeekableIterator.close() 正确转发到底层 Resource。
- ✅ **LevelManager copy+CAS 一致性**: 所有 add/remove/get 使用 AtomicReference.load/CAS，snapshot 不可变性保证。
- ✅ **MemTableManager swap**: CAS 确保单线程 swap 成功，另一方返回 None 重试，无并发竞态。
- ✅ **WAL append + rotate**: appendLock 保护 write+rotate 原子性，无数据丢失路径。
- ✅ **DateTime.now() 开销**: Store.get() 热路径入口一次获取以参数传递；PrefixIterator.next() 循环内实时获取（vDSO ~300ns/次，非问题）。
- ✅ **SSTable.get() Ln 无 Bloom 检查**: Ln 已用 minKey/maxKey 范围筛选，Bloom Filter 无额外收益，设计选择。
- ✅ **原子聚合缓存**: levelSizes[level] AtomicInt64 增量缓存，add/remove 时原子更新，无精度问题。
