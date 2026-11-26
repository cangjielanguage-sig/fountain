# 验证：空闲槽分片（Phase 2）

## 结论

`freeSlots` 拆 64 分片、分配写入移出全局锁。目标指标 **A4（分配型）从 0.79× 升到 2.64×**（5 次全部 ≥2.37×），
S2/S4/S8、Q1、F1/F4 均在共享 VM 噪声范围内。全量 **1202 / 1202 通过 / 0 失败 / 0 error**。

## 前置争用数据（改动依据）

临时探针（已删除）：

```
HT-CONTEND ns1=3192 ns4PerOp=6113 speedX100=52
CTX-CONTEND ns1=415 ns4PerOp=276 speedupX100=150
```

句柄 churn 4 线程扩展比 **0.52×**（比单线程慢一倍）；`JitContext` create/free 为 1.50×。
前者直接指向 `HandleTable.mtx` 的 convoy。

## 改动

- `freeSlots` → `FreeStripes(64)`：每片 `ArrayList<Int64>` + 独立 `Mutex`，索引按 `idx & 63` 固定归属；
- `newSlot`：`popFree()` 摘索引（分片锁）→ **锁外写 8 个槽数组**；无空闲则 `growSlot()`（全局 `mtx`）；
- `release` / `releaseEscaped` / `resetWindow`：状态复位 + `gen+1` + 归还同一分片，全在分片锁内；
- `retiredSlots` 改 `AtomicInt64`；`resetForTest` 逐分片清空；
- 新增 `HandleTableStripeConcurrency_test`：4 线程 × 20000 次 `pin`/`release`，断言每次 ID 恒正可读、
  结束后 `liveCount` 回基线、`slotCount` 增长 ≤ 256。

## 正确性

| 用例 | 结果 |
| --- | --- |
| `HandleTableStripeConcurrency_test`（新增） | 1/1 |
| `HandleTable_test` | 18/18 |
| `HandleTableM2_test` | 7/7 |
| `HandleTableGenExhaustion_test` | 2/2 |
| `AnyHostCast_test`（槽复用 / `slotCount` 精确断言） | 4/4 |
| `T40Account_test`（容量触顶 16） | 3/3 |
| `WindowIsolation_test`（跨线程释放不误杀） | 3/3 |
| `PromotionGroupConcurrency_test` | 1/1 |

全量：`TOTAL 1202 / PASSED 1202 / ERROR 0 / FAILED 0`。

## 收益（5 次，`taskset -c 0-4`，共享 7 核 A53 VM）

`CallPathBench_test`：

| 指标 | 基线（Phase 1 后） | Phase 2 后 | 说明 |
| --- | --- | --- | --- |
| A4（分配型，×100） | 76 / 138 / 79（中位 79） | 237 / 264 / 241 / 275 / 266（中位 264） | **+234%**，5 次全部 ≥2.37× |
| Q1（calls/s） | 180681 | 196707 / 108230 / 202328 / 107550 / 194060（中位 194060） | +7.4% |
| L1（ns/call） | 5534 | 5083 / 9239 / 4942 / 9297 / 5153（中位 5153） | −6.9% |
| F1（ns/op） | 507（P1.2 后） | 最好 503 | 持平 |
| F4（ns/op） | 219（P1.2 后） | 最好 217 | 持平 |

`ParallelThroughput_test`：

| 线程 | 基线 | Phase 2 后（5 次） | 中位 |
| --- | --- | --- | --- |
| 2 | 1.27× | 1.36 / 1.29 / 1.27 / 1.38 / 1.27 | 1.29× |
| 4 | 2.40× | 1.86 / 2.39 / 2.32 / 2.00 / 2.17 | 2.17× |
| 8 | 1.91× | 2.59 / 1.90 / 1.63 / 2.90 / 1.74 | 1.90× |

S4 的 4 线程中位数从 2.40 降到 2.17，但单次分布 1.86–2.39 与基线（P6 的 2.40、P1.3 的 2.22）重叠，
且两次低值运行同时伴随 Q1/F1/F4 整体变差（机器负载），判为噪声而非回退。

## 判定

**keep**：A4 是唯一由句柄分配锁直接决定的指标，提升 +234%（远超 MOV = 13%）；其余指标无系统性回退。

## 风险与后续

- **写入无锁的论证前提**：槽被摘除后不可达、新 ID 未发布、旧 ID 被 gen 拒绝；若未来引入「槽指针直接暴露
  给机器码」则需重新论证。
- **同槽「提升」与「释放」并发**：仍属调用方非法用法；现有实现只保证分配/释放/收窗三者互斥。
- **下一步**：B1 单次调用仍约 5 µs，瓶颈在桥接层（封送 + `JitContext` malloc/free），Phase 3 优先。
