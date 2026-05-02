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

### ✅ 统一性能测试（已完成）

已执行 `-j1` + `-j8` benchmark，所有 case 无退化（±2% 噪声范围内）。SSTable 优化在 benchmark 中不体现（数据全在 MemTable）。

---

## ✅ P2.2 — ByteArray hashCode 缓存（已完成）

Constructor 中预计算 `hash` 字段，`hashCode()` 直接返回。替代原每次遍历全量字节的 `HashBuilder.append().build()`。

**实际实现**：在构造函数中计算并保存 `hash: Int64`，避免 `mut func` 需要（Cangjie struct 的 `Hashable.hashCode()` 不可声明为 `mut`）。

## ✅ P3 — LevelManager.get() 早期退出（已完成）

新增 `totalSSTableCount: AtomicInt64`，在 `addSSTable()`/`removeSSTables()`/`loadExisting()` 时同步更新。
`get()` 入口检查 `totalSSTableCount.load() == 0` 时直接返回 None，跳过 7 层循环。
