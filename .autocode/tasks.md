# 当前任务

## ✅ 性能优化：WAL 编码零分配路径（已完成）

WAL.append() 热路径引入 ThreadLocal 编码缓冲区，每次 append 从 2 次堆分配降为 0 次。benchTTL -10.4%。

## ✅ 性能优化：SSTable 读路径分配消除（已完成）

### ✅ P1 — scanBuffer kBuf → 零拷贝切片比较

`SSTable.scanBuffer()` 中 `Array<Byte>(keyLen)` 堆分配替换为 `buf[offset .. offset + keyLen]` 零拷贝切片直接与 `targetKey` 比较。消除每次记录扫描的 1 次分配 + 1 次拷贝。

### ✅ P2.1 — Bloom Filter 双重检查消除

- SSTable 新增 `getDirect(key: ByteArray): ?EntryValue`（跳过内部 bloom 检查，直接二分 → pread → scanBuffer）
- `get()` 抽取公共部分为 `readBlockAndScan()`，保留 bloom 作为公共 API 保护
- `LevelManager.getInLevel()` 两处 `sst.get(key)` 替换为 `sst.getDirect(key)`

### ☐ 统一性能测试（待执行）

所有优化完成后统一执行：
```
cd f_store
cjpm build -i -j1
cjHeapSize=8GB cjpm bench -j1
cjHeapSize=8GB cjpm bench -j8
```
更新 README.md 及 tasks.md。

### 📋 ByteArray 分配消除（P2.2 — 待验证）

`Store.get()`/`add()`/`remove()` 中每次 `ByteArray(key)` 堆分配是否可消除。需要实验验证 CSLM 是否可接受 `Array<Byte>` 作为 key。暂不实现。
