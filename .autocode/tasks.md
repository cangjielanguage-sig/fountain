# f_store 代码审查报告

> 审查日期：2026-05-02
> 来源：全面静态审查 f_store/src/*.cj 生产代码
> 已知问题已记录在 `f_store/doc/优化方案.md`，以下仅报告新增发现

---

## [P3] LevelManager.getInLevel() 中 BloomFilter/Metadata 的 StoreClosedException 未捕获 ✅

- **问题等级**: P3
- **问题描述**: `getBloomFilter()` (L0) 和 `getMetadata()` (Ln) 在 `isClosed()` 检查之后、try-catch 之外调用。若 Compaction 在这两个方法前关闭 SSTable，`guardReadable()` 抛 `StoreClosedException`。
- **修复**: 将 `getBloomFilter()` 和 `getMetadata()` 移入已有的 try-catch 块，与 `sst.get(key)` 共用保护。
- **测试**: 182/182 全量通过。
- **提交**: (待提交)
