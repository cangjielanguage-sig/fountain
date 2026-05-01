# f_store 代码审查优化项

## P0 — 必须修复

### 修复P0 BUG-1+Q-1: SSTable.get() pread关闭fd后读竞争+忽略返回值
- **位置**: SSTable.cj L77(保存fd), L292-301(get使用pread), L446-457(close关闭file)
- **问题**: Linux路径上get()使用构造时保存的fd; close()关闭file后fd被回收, pread返回-1但返回值被丢弃, scanBuffer在全零缓冲区扫描最终返回None
- **非Linux**: synchronized(getLock)已被close()的drain正确保护
- **修复**: 检查positionedRead返回值, 失败时调用guardNotClosed()

## P1 — 性能优化

### 优化P1 PERF-1: Compaction归并改用优先级队列
- **位置**: SSTableMerger.cj L36-46
- **问题**: 每次next()遍历所有m个源找最小key, O(n×m)无优先级队列
- **改法**: 二叉堆/优先级队列, 降至O(n×log m)

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
