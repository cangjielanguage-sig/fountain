# 任务

> 数值口径：`gen` 从 1 起，每释放一次 +1；`GEN_MAX = 0x7FFF`（32767）。
> 因此「第 32767 次复用」的 gen 恰为 32767，其后的释放必须退休。

- [x] G1.1 **Red 用例**（只用现有 API）：`HandleTableGenExhaustion_test`
  - 循环 32768 轮：`openWindow` → `pin('x')` → 断言 `id > 0`、`isLiveHandle`、`getAny` → `release` → `resetWindow`；
  - 旧实现第 32768 轮返回负 ID ⇒ `id > 0` 断言失败（确认是断言红，不是编译错）；
  - 记录失败轮次，确认与本设计的 32768 一致。

- [x] G1.2 **实现**：`GEN_MAX = 0x7FFFu16`；新增 `freeOrRetireLocked(seg, off, i)`；
  4 处释放点（`releaseConst` / `release` / `releaseEscaped` / `resetWindow`）改调该函数；
  新增 `retiredSlots` 计数 + `retiredCount()`；`resetForTest` 清零。

- [x] G1.3 **Green**：复跑用例全绿；补三条断言（退休计数 = 1、`slotCount` 恰增 1、
  退休前最后一个 ID 读取为空 / 判死 / 释放不误伤新槽）。

- [x] G1.4 **变异验证**：临时把 `freeOrRetireLocked` 改回「无条件 +1 并归还空闲表」，
  G1.1 用例必须重新变红（第 32768 轮 `id > 0` 失败）；验证完恢复。

- [x] G1.5 **回归**：`HandleTable_test` / `HandleTableM2_test` / `AnyHostCast_test` /
  `T40Account_test` / `PromotionGroupConcurrency_test` / `WindowIsolation_test` 单类通过；
  全量 `cjpm test --parallel 1` 零失败（已知 `PerfOverride_test` 高负载假失败需单跑确认）。

- [x] G1.6 **解除基准限制**：`CallPathBench_test` 的 B3 迭代次数恢复到 15000（原为规避 gen 阻断
  降到 5000），复跑确认稳定；`doc/optimize-call-path.md` §10 状态改为「已修复」并指向本变更。

- [x] G1.7 **文档与校验**：README（中/英）句柄编码说明已补「gen 上限 0x7FFF，耗尽退休」；
  `openspec validate fix-handle-gen-exhaustion --strict` 通过；镜像落盘
  `f_jit/doc/spec/fix-handle-gen-exhaustion/`；已归档 `2026-11-27-fix-handle-gen-exhaustion`。

## 不做

- 不改 ID 位域布局（`gen:16 | tag:16 | idx:32` 保持不变）；
- 不回收退休槽（记入 design 风险：受 `capacityLimit` 既有上限约束）；
- 不改 `IterTable` 的游标编码（与句柄 ID 无关）。
