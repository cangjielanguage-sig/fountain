# f_store 代码审查优化项

## P0 — 必须修复 ✅

### ✅ 修复P0 BUG-1+Q-1: SSTable.get() pread关闭fd后读竞争+忽略返回值
- **提交**: `4fdd9051`

## P1 — 性能优化 ✅

### ✅ 优化P1 PERF-1: Compaction归并改用优先级队列
- **提交**: `9496307f`
- **改法**: PriorityQueue二叉堆替代O(m)扫描, O(n×m)→O(n×log m)

## P2 — 健壮性/性能

### 优化P2-1 Q-2: SSTable.state改用Atomic
- **位置**: SSTable.cj L70
- **问题**: state字段非Atomic且close()写入无内存序保证

### 优化P2-2 PERF-2: SSTableIterator改为pread
- **位置**: SSTableIterator.cj L211-213
- **问题**: loadBlock()用seek+read 2 syscalls, Linux可简化为1个pread

## P3 — 测试补充

### 优化P3 TEST-1: close+read并发测试
- **位置**: Concurrency_test.cj
- **问题**: 未覆盖close()期间并发get()的测试

## P2 — 健壮性/性能

### 优化P2-1 Q-2: SSTable.state改用Atomic
- **位置**: SSTable.cj L70
- **问题**: state字段非Atomic且close()写入无内存序保证

### 优化P2-2 PERF-2: SSTableIterator改为pread
- **位置**: SSTableIterator.cj L211-213
- **问题**: loadBlock()用seek+read 2 syscalls, Linux可简化为1个pread

## P3 — 测试补充

### 优化P3 TEST-1: close+read并发测试
- **位置**: Concurrency_test.cj
- **问题**: 未覆盖close()期间并发get()的测试
