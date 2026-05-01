# f_store 代码审查优化项

## P0 — 必须修复 ✅

### ✅ 修复P0 BUG-1+Q-1: SSTable.get() pread关闭fd后读竞争+忽略返回值
- **提交**: `4fdd9051` (fix) + `869e29e5` (pread引入)
- **背景**: 
  - `869e29e5` 引入pread替代seek+read消除L0多SSTable并发get的seek竞争。Linux用pread+fd，非Linux用synchronized(getLock)保护。close()添加synchronized(getLock){}空守卫等待reader完成。
  - `4fdd9051` 发现残留竞争：Linux上pread用构造时保存的fd，close()关闭file后fd被回收，pread返回-1但返回值被丢弃，scanBuffer在全零缓冲区扫描最终返回None。
- **修复**: 
  1. `guardNotClosed()` 新增辅助方法，pread失败后检查`closed.load()`
  2. Linux get()路径检查`positionedRead`返回值，失败时先调`guardNotClosed()`区分关闭竞争vs I/O错误，再返回None

## P1 — 性能优化 ✅

### ✅ 优化P1 PERF-1: Compaction归并改用优先级队列
- **提交**: `9496307f`
- **改法**: PriorityQueue二叉堆替代O(m)扫描, O(n×m)→O(n×log m)

## P2 — 健壮性/性能

### ✅ 优化P2-1 Q-2: SSTable.state改用Atomic
- **提交**: `120fc298`
- **改法**: AtomicInt64 + static const 常量替代 var 字段

### ✅ 优化P2-2 PERF-2: SSTableIterator改为pread
- **提交**: `ca4127d5`
- **改法**: loadBlock() Linux用pread, 非Linux保持seek+read

## P3 — 测试补充

### 优化P3 TEST-1: close+read并发测试
- **位置**: Concurrency_test.cj
- **问题**: 未覆盖close()期间并发get()的测试
