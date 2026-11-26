# 设计：空闲槽分片与分配路径去全局锁

## D1 锁的归属

| 数据 | 保护者 | 理由 |
| --- | --- | --- |
| 空闲索引表（64 分片） | 分片锁 `idx & 63` | 高频；分片后争用降为 1/64 |
| 槽状态（`alive/gens/objs/tags/…`） | 该槽所属分片锁（仅生命周期跃迁时） | 同槽的分配/释放天然串行，双释放幂等 |
| `totalSlots` 与段发布 | 全局 `mtx` | 每 1024 槽一次；段地址必须发布后才可被引用 |
| 常量引用计数 `constRefs` | 全局 `mtx` | 常量路径跨调用共享、频率低 |
| 窗口记账（`Win`） | 线程私有（P1 已完成） | 每调用独占 |

## D2 分配（`newSlot`）

```text
idx = popFree()            // 逐分片尝试，命中即返回；全空 → -1
if idx < 0:
    idx = growSlot()       // mtx: capacityLimit 检查 + ensureSegLocked + totalSlots++
写 objs/tags/gens/alive/constFlags/…   // 无锁：索引已摘除，任何线程都拿不到
```

**为什么写入可以无锁**：槽被摘除后不在任何空闲表、`alive=false`；新 ID 尚未交给调用方。
持旧 ID 的读者会被 `gens` 不匹配拒绝（释放时已 +1）。因此写入者对该槽独占。

## D3 释放（`release` / `releaseEscaped` / `resetWindow`）

```text
synchronized(stripeMtxs[idx & 63]):
    复核 alive && gens == genOf(id) && !constFlags
    复位 alive/objs/escape/frozen
    gens += 1；未到上限 → 归还该分片；到上限 → 退休
```

- 双释放：两个线程在同一分片锁上串行，后者看到 `gens` 已变 ⇒ 幂等返回。
- `resetWindow` 逐槽取锁（而不是整段持 `mtx`）：窗口槽彼此独立，逐槽更细。
- `escapeFlags` 仍由 `mtx` 侧（`moveOutGroup`/`escape`）写；同槽「提升」与「释放」并发属调用方
  非法用法（持有同一句柄同时提升又释放），不在本变更承诺范围。

## D4 增长与容量

- `growSlot` 在 `mtx` 内：`idx >= capacityLimit` ⇒ 16；`ensureSegLocked` 建段；`totalSlots += 1`。
- 段发布顺序：先填满 `SlotSeg` 各数组，再把引用写入 `segDir`（数组元素写），最后返回 idx。
  读者要拿到新 ID 必须经过线程间同步（spawn/通道/锁），存在 happens-before ⇒ 能看到已发布的段。
- 退休槽不进任何分片（`retiredCount` 不变）。

## D5 复位

`resetForTest`：逐分片清空（各自锁），再清 `totalSlots/retiredSlots`，最后重建哨兵。仅测试调用。

## D6 验证

1. **行为不变**：全量 1201 条；重点 `HandleTable_test`（槽复用/世代号）、`HandleTableM2_test`、
   `AnyHostCast_test`（1000 次循环后 `slotCount == base+1`）、`T40Account_test`（容量触顶 16）、
   `WindowIsolation_test`（跨线程释放不误杀）、`PromotionGroupConcurrency_test`。
2. **并发正确性**：现有并发集 3 轮；另补一条「4 线程各自 pin/release × 20000 次，结束后
   `liveCount` 回基线、无重复活槽」的用例（成本低，直接压分配路径）。
3. **收益**：`CallPathBench_test` 与 `ParallelThroughput_test` 各 5 次；A4/S4 达 MOV 且其它指标
   回退 ≤2% 才保留。

## 风险

| 风险 | 处置 |
| --- | --- |
| 分片后索引分布不均，`popFree` 扫描 64 次 | 空闲表满时首个命中；空表时扫描 64 次可忽略（随后走增长） |
| 槽写入无锁导致理论数据竞争 | 写入发生在发布前，读者只能持旧 gen（被拒）；已在 D2 论证 |
| `release` 与 `moveOutGroup` 并发 | 属调用方非法用法；现有测试不覆盖，文档声明 |
| 分片锁与 `mtx` 的锁序 | 任何路径都不得「持分片锁再取 `mtx`」；`popFree` 先释放分片锁再 `growSlot` |
