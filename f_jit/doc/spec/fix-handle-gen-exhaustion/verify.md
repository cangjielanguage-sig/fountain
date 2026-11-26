# 验证：句柄世代号耗尽（gen 溢出）

## 结论

`gen` 上限收到 `0x7FFF`、耗尽即退休；句柄标识恢复「恒正」不变量。
Red 用例在旧实现上以 `OverflowException`（`makeId:227`）失败，实现后 2/2 通过，去掉退休分支的变异可重新变红。
全量 **1201 / 1201 通过 / 0 失败 / 0 error**。

## Red（实现前）

命令：`cjpm test --filter "HandleTableGenExhaustion_test*" --parallel 1 --show-all-output`

```
[ ERROR  ] CASE: genExhaustionKeepsIdsPositiveAndReadable
REASON: An exception has occurred:OverflowException: The result would be greater than Int64.Max.
    at HandleTable.makeId(...) (HandleTable.cj:227)
    at HandleTable.newSlot(...) (HandleTable.cj:1042)
    at HandleTable.pin(...) (HandleTable.cj:398)
[ ERROR  ] CASE: retiredSlotIdsStayDead
REASON: 同上
Summary: PASSED: 0, SKIPPED: 1199, ERROR: 2
```

失败点是第 32768 次分配同一槽（0 基第 32767 轮），与 design 的溢出点一致。
注：Red 阶段用例里 `retiredCount()` 断言暂以常量替代（该 API 尚未实现），核心断言
「ID 恒正 + 可读」未作任何放宽。

## Green（实现后）

```
GEN-PROBE rounds=32768 badRound=-1 badId=0 unreadableRound=-1 slotCount=3 base=1 retired=1 lastId=281487861612546
Summary: PASSED: 2, SKIPPED: 1199, ERROR: 0
```

- `badRound=-1`：32768 次复用每次 ID 均为正；
- `slotCount=3`（base=1）：退休 1 个槽 + 新槽接管，高水位恰增 2；
- `retired=1`：退休计数与实际一致；
- 第二条用例：退休前最后一个 ID `isLiveHandle=false`、`getAny=None`，显式 `release` 不误伤新槽。

## 变异验证

把 `freeOrRetireLocked` 改回「无条件 `+1` 并归还空闲表」：

```
Summary: PASSED: 0, SKIPPED: 1199, ERROR: 2   (exit=1)
```

两条用例同时变红 ⇒ 用例确实锁住了退休分支。验证后已恢复实现。

## 单类回归

| 用例 | 结果 |
| --- | --- |
| `HandleTableGenExhaustion_test` | 2/2 |
| `HandleTable_test` | 18/18 |
| `HandleTableM2_test` | 7/7 |
| `AnyHostCast_test` | 4/4 |
| `T40Account_test` | 3/3 |
| `PromotionGroupConcurrency_test` | 1/1 |
| `WindowIsolation_test` | 3/3 |

## 全量

```
Summary: TOTAL: 1201
    PASSED: 1201, SKIPPED: 0, ERROR: 0
    FAILED: 0
```

（`cjpm test --parallel 1 --no-color --no-progress`，一次通过，无已知性能假失败。）

## 基准解禁

`CallPathBench_test` B3 迭代次数 5000 → 15000，单跑 3 次均 `exit=0`、`jitBacked=1`：

| 轮次 | A4（×100） | Q4（calls/s） |
| --- | --- | --- |
| 1 | 76 | 483217 |
| 2 | 138 | 255867 |
| 3 | 79 | 471970 |

B3 已可跨过 32768 次复用边界（不再抛 99）；A4 仍受共享 VM 噪声影响，**不作为 Phase 2 的判定指标**，
需专用机器或改短调用口径后重采。

## 风险与后续

- **索引空间**：退休槽永久占用索引位，分摊 3e-5 槽/次分配；`capacityLimit`（默认 1M）仍是既有上限，
  达到后按既有 16 失败。若未来需要回收退休槽，应作为独立变更（需重新论证「旧标识永久失效」）。
- **位域余量**：若把 `idx` 收到 31 位、`gen` 用满 47–62 位，可把退休阈值翻倍到 65535；
  当前无必要（已验证 4M 目录足够），记为后续可选项。
