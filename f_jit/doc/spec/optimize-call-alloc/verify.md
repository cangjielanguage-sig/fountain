# 验证记录：`optimize-call-alloc`（窗口对象复用）

> 环境：共享 7 核 A53 VM（load 4.0–5.4），`taskset -c 0-4`，`cjpm test --parallel 1`。

## 1. 基线

| 测量 | 数据 |
| --- | --- |
| `openWindowWith + resetWindow(rs)`（改动前探针） | 601 ns/op |
| `emptyAllocs`（2 个空对象） | 336 ns |
| GC 分配合计 | ~1.0–1.4 µs（慢峰 17–24%） |

## 2. A/B（同轮配对：复用版 vs 「每次 new」变异）

| 臂 | 原始值（ns/op） |
| --- | --- |
| 复用（`freeWins` 池） | **241 / 236 / 430** |
| 每次 new（`acquireWin`/`recycleWin` 恒不命中） | **632 / 333** |

| 峰 | 每次 new → 复用 | Δ |
| --- | --- | --- |
| 慢峰 | 632 → 430 ns | **−32%** |
| 快峰 | 333 → 236 ns | **−29%** |

历史基线 601 ns 与复用后 236–430 ns 同向，**判定 keep**（远超 MOV，`L1` 约 −300~370 ns）。

## 3. 正确性

- 全量 **1230/1230 / 0 失败**（新增 `WindowPool_test` 2 条）。
- 护栏：
  1. `repeatedOpenResetKeepsState`：连续 1000 次开合，容量正确、`windowUsed == 0`、环境窗口复原；
  2. `liveCountReturnsToBaseline`：连续 1000 次开合，活槽计数回基线（reset 释放行为不变）。
- `WindowIsolation_test` / `HandleTable*` / `UnloadConcurrency_test` 全绿。

## 4. 变异

| 变异 | 预期 | 实测 |
| --- | --- | --- |
| `acquireWin` / `recycleWin` 恒不命中（每次 new） | 功能全绿、仅变慢 | 用于 A/B 臂 |
| `acquireWin` / `recycleWin` 不清 `used` | `reusedWindowStartsClean` 变红 | **1 条红**（另 2 条绿），已恢复 |

> `pins` 残留不会造成功能错误：`pin` 的窗口去重会先检查 `seg.alive` 与 `gen`，
> 陈旧 ID 直接跳过（只是多扫一条）。因此「不清 `pins`」不是有效变异形态。

## 5. 影响文件

- `src/runtime/RuntimeState.cj`：`freeWins`（≤8）；
- `src/runtime/HandleTable.cj`：`acquireWin` / `recycleWin`，`openWindowWith` 与 `resetWindow` 改走池；
- 新增 `src/WindowPool_test.cj`。

## 6. 残留

- `CallMarshal` 的 2 个 `ArrayList`（约 340 ns）未池化：它是根包类，放进 runtime 的
  `RuntimeState` 会形成子包反向依赖；用 `ThreadLocal` 池又要付一次 TLS（≈300 ns），
  收益被抵消。留待「改为惰性 `Option<ArrayList>`」单独评估。
- `cells` 数组（约 168 ns）亦未池化，理由同上（跨包访问）。
