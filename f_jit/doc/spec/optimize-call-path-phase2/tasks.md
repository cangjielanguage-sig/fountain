# 任务

- [x] H1.1 **基线**（改动前）：`CallPathBench_test` A4 = 76 / 138 / 79（×100）；
  S2/S4/S8 基线取 Phase 1 记录（1.27 / 2.40 / 1.91），Phase 2 后用同机 5 次复测对照。

- [x] H1.2 **并发护栏用例先行**：`HandleTableStripeConcurrency_test`
  - 4 线程各自 `openWindow` / `pin` / `release` / `resetWindow` × 20000 次；
  - 断言：全部 ID 为正且可读、结束后 `liveCount() == 基线`、`slotCount` 增长 ≤ 线程数 × 64
    （分片缓冲导致的高水位，不含退休）；
  - 旧实现应通过（这是护栏，不是 Red）：先确认 3 轮绿。

- [x] H1.3 **实现**：
  - `freeSlots` → `freeStripes[64]` + `stripeMtxs[64]`；
  - `pushFree(idx)` / `popFree()`（先本线程偏好分片，再轮询）；
  - `newSlot`：分片锁内摘索引、锁外写槽；增长走 `growSlot()`（`mtx`）；
  - `release` / `releaseEscaped` / `resetWindow` 改用分片锁；`freeOrRetire` 改名为无锁前提版本；
  - `resetForTest` 逐分片清空。

- [x] H1.4 **正确性回归**：`HandleTable_test` / `HandleTableM2_test` / `AnyHostCast_test` /
  `T40Account_test` / `WindowIsolation_test` / `PromotionGroupConcurrency_test` /
  `HandleTableGenExhaustion_test` 单类通过；并发集 3 轮。

- [x] H1.5 **全量**：`cjpm test --parallel 1` 零失败（1201 条 + 新增 1 条）。

- [x] H1.6 **复测与判定**：`CallPathBench_test` × 5、`ParallelThroughput_test` × 5；
  记录 A4/Q4/Q1/F1/F4/S4 中位数与离散度；按 `optimize-call-path.md` §1 判定 keep / revert。

- [x] H1.7 **文档**：`doc/optimize-call-path.md` 已填 §6/§7 与新增 §11；归档 `2026-11-27-optimize-call-path-phase2`。

## 不做

- 不做每槽原子字 / 无锁栈；
- 不改 `JitContext` 池化（Phase 3）；
- 不改公开 API。
