# f_store 代码审查改进计划

> 来源：全面审查 f_store 代码。
> 优先级：P0 必修、P1 建议、P2 可选、P3 暂缓。

---

## P0 必修

### WAL.append 写已关闭文件 ✅

- **文件**: `f_store/src/WAL.cj:84-87`
- **问题**: append() 中 file.write(encoded) 之后，另一线程 rotate() 可能关闭该 File 并创建新文件，当前线程在上写入已关闭的文件句柄引发异常。
- **改进方案**: 用 Mutex 保护 file.write + rotate 临界区，或将 file 改为 AtomicReference<File> 并在写前 load。在 append() 中加 synchronized(mutex) 包裹 file.write 和 size 检查。
- **已修复**: 新增 appendLock Mutex，在 append() 中用 synchronized(appendLock) 保护 file.write + size 检查 + rotate，在 close() 中同样用 appendLock 保护。移除了不再需要的 rotating AtomicBool。

---

## P1 建议

### SSTableIterator FD 泄漏

- **文件**: `f_store/src/SSTableIterator.cj:28-29`, 调用点在 `SSTable.cj:266-274`
- **问题**: iterator()/tailer() 每次打开独立 File 句柄。调用者 break 提前退出循环时 FD 泄漏。高频前缀扫描场景（多 SSTable + 高 QPS）可能在数分钟内耗尽系统 FD 限制。
- **改进方案**: (a) iterator/tailer 调用点全部改用 `try(iter = sst.iterator())` 确保退出时自动 close；(b) 或在 SSTableIterator 中加引用计数 / 注册到 SSTable 的生命周期管理。

### SSTable.close() 非 Linux 与 get() 竞争

- **文件**: `f_store/src/SSTable.cj`
- **问题**: close() 用 `synchronized(getLock){}` 空等 pending reads，但释放锁后 file.close() 之前新 get() 可能获取锁开始 I/O，随后被突然关闭的文件打断。
- **改进方案**: 将 `file.close()` 移入 `synchronized(getLock){}` 块内执行。注：Linux 用 pread 无此问题。

### Store.get() 重复 DateTime.now() ✅

- **文件**: `f_store/src/Store.cj:114-128`, `f_store/src/LevelManager.cj:62`
- **问题**: get() 走 MemTable → Immutable → LevelManager 三路径时每段都新调 DateTime.now()。同一请求中调用 2-3 次系统调用。
- **改进方案**: 在 Store.get() 入口调用一次 DateTime.now()，将 now 作为参数沿调用链传递到 checkExpiryAndGet 和 LevelManager.get。
- **已修复**: Store.get() 顶部计算一次 now，checkExpiryAndGet 接受 now 参数，3 次调用复用同一个 now。

### Compaction 异常孤儿文件

- **文件**: `f_store/src/Compaction.cj:117-131`
- **问题**: compact() 中 writer.write 或 finishWrite 抛出异常时，当前 writer 的 File 句柄泄漏、已写入部分数据的 .sst 文件成为孤儿。
- **改进方案**: 在 merge 循环外围加 try-finally，catch 时 close writer 并删除临时文件。

---

## P2 可选

### WAL 恢复阶段大文件全量读入内存

- **文件**: `f_store/src/WALReader.cj:21-22`
- **问题**: readAll() 将整个 WAL 文件读到 Array<Byte>（最大 64MB），启动时一次性分配偏大。
- **改进方案**: 改为流式读取：边读边解析边恢复，不需全量加载。或维持现状（一次性启动可接受）。

### flushMemTable 无 try-finally

- **文件**: `f_store/src/store_func.cj:136-152`
- **问题**: 循环中 writer.write() 或 memTable.iterator() 异常时 writer 的 File 句柄不关闭。
- **改进方案**: 在 if-entry-count=0 的 close 前加 try-finally 确保 writer 在异常时也关闭。

### PrefixIterator O(n) 扫描

- **文件**: `f_store/src/PrefixIterator.cj:27-73`
- **问题**: next() 每步 O(n) 扫描所有 sources 找 minKey 和匹配条目，而非 O(log n) 堆。
- **改进方案**: 参考 SSTableMerger 用 PriorityQueue 替换线性扫描。

---

## P3 暂缓

### ByteArray.compare 伪 8 字节批量优化

- **文件**: `f_store/src/ByteArray.cj:26-35`
- **问题**: while(8)+for(0..8) 仍然是逐字节比较，外层的 "8 字节" 内层只是循环展开，无实际性能增益。代码具有误导性。
- **改进方案**: 简化为一层 while 循环逐字节比较。或真正用 unsafe 指针转换为 UInt64 做 8 字节整数比较。

### SSTableIterator.skipBefore 冗余边界检查

- **文件**: `f_store/src/SSTableIterator.cj:58-75`
- **问题**: skipBefore() 和 next() 中有约 20 行重复的溢出检查代码模式。
- **改进方案**: 提取公共的 readRecordLen/checkOverflow 辅助函数。

### WAL.rotate 中使用 var 而非 AtomicReference

- **文件**: `f_store/src/WAL.cj`
- **问题**: `this.file` 是 var 而非 AtomicReference，append() 中读取 this.file 不保证可见性（但 P0 修完加 Mutex 后解决）。
- **改进方案**: P0 的 Mutex 方案已覆盖此问题，无需单独处理。

---

## 修复顺序建议

```
1. P0 WAL.append 写已关闭文件（Mutex）
2. P1 Store.get() 重复 now()（传参）
3. P1 Compaction 孤儿文件（try-finally）
4. P1 SSTableIterator FD 泄漏（调用点加 try）
5. P1 SSTable.close() 非 Linux 竞争（synchronized 内 close）
```
