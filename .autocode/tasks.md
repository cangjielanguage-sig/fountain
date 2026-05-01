# f_store 代码审查 → 改进计划

审查结论：全部 20 源文件（~2,816 行）已审查完毕。

## P0 — BUG：WAL.oldFiles 无同步保护 ✅ 已完成
- **文件**: WAL.cj:29,81-88,96
- **问题**: `oldFiles: ArrayList<String>` 被 `rotate()`(单线程)的 add 和 `takeOldFiles()`(多线程)的 for+clear 并发读写，无同步保护
- **修复**: 加 Mutex 保护 oldFiles 的 add 和 takeOldFiles 操作

## P1 — 文件覆盖：Compaction 文件名冲突
- **文件**: Compaction.cj:144
- **问题**: Compaction 用本地变量 `sstIndex=0`，flushMemTable 用全局 `sstableFileSeq`。两次 Compaction 到同一 level 产生同名.sst 文件，OpenMode.ReadWrite 覆盖旧文件 inode，旧 SSTable 对象的 fd 读到被覆盖后的数据（可能损坏）
- **修复**: Compaction 使用 `sstableFileSeq.incrFetch()`

## P2 — 资源泄漏：SSTableIterator 不释放 File 句柄
- **文件**: SSTable.cj:328,334, SSTableIterator.cj:19-27
- **问题**: iterator()/tailer() 每次打开独立 File 句柄，SSTableIterator 无 close()，句柄永不释放
- **修复**: SSTableIterator 实现 Resource + close()，调用方（SSTableMerger、PrefixIterator）负责关闭

## P3 — 优化：PrefixIterator 频繁 DateTime.now()
- **文件**: PrefixIterator.cj:107
- **问题**: 每次 next() 都调 DateTime.now()，可缓存一次
- **修复**: init() 时缓存 now
