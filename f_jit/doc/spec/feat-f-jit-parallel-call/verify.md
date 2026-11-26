# Verify（P0–P6，2026-11-26）

> 本变更全部阶段（P0–P6）已实施；归档前请复核「未完成 / 风险」中的 API 命名漂移。

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线 | 1178 用例 / 1178 通过 / 0 失败 |
| P1 终态 | 1181 用例 / 1181 通过 |
| P2 终态 | 1184 用例 / 1184 通过 |
| P3 终态 | 1184 用例 / 1184 通过（真实并发） |
| P4 终态 | 1185 用例 / 1185 通过 |
| P5 终态 | 1187 用例 / 1186 通过（`PerfOverride` 假失败，单跑通过） |
| P6 终态 | **1188 用例 / 1188 通过 / 0 失败 / 0 error / 0 skipped**（含基准用例，一次通过） |
| 新增 | 10 条（`WindowIsolation_test` 3 + `ThreadLocalEnv_test` 3 + `PromotionGroupConcurrency_test` 1 + `UnloadConcurrency_test` 2 + `ParallelThroughput_test` 1） |
| 回归 | 0 |

命令：`unset CJPM_CONFIG && cjpm test --parallel 1 --no-color --no-progress`。

> P1/P2 各有一次全量运行唯一失败为既有性能用例 `PerfOverride_test.overrideBeatsReflectionEndToEnd`：
> 一次净成本 3324 ns 超阈值，另一次反射耗时低于基线导致净成本被钳成 1 ns；两次单跑均通过。
> 属已知环境噪声，与本次改动无关。P3/P4 代码均一次全量通过（P3 1184/1184，P4 1185/1185）。
> P5 的两次全量均只有该性能用例失败（净成本 5429/6710 ns），单跑通过；其余 1186 条全绿。

## 实施内容

| 任务 | 落地 |
| --- | --- |
| P0 | 分块存储：1024 槽/段，目录定长 4096 项（4M 槽），段惰性分配、地址不变 |
| P1.1 | 新增并发窗口隔离用例（直接调 `HandleTable`，绕过 `callMtx`） |
| P1.2 | 窗口记账 + 窗口栈改 `ThreadLocal`；`hwBase/hwCap/hwTop` 为每线程真值 |
| P1.2b | `getAny/getAs/isType/tagOfHandle/tagOrZero/fetch*/isLiveHandle/isConst/isEscaped/isFrozen` 无锁读 |
| P1.2c | `pin/pinHostObject/pinHostClosure` 去重收窄到本窗口（路径 C + 路径 B 清单），删除全表线性扫描 |
| P1.3 | 重入窗口栈线程私有 |
| P1.4 | `IterTable` 改 `ThreadLocal<IterState>`，去掉全局锁 |
| P2.1 | `RuntimeEnv.deadlineNanos` / `MachineEnv.fnTableBase` 改 `ThreadLocal`（`static mut prop` 保持读法不变）；`UserHelperTable.stack` 线程私有；删 `JitExecutor.envMtx` |
| P2.2 | 新增 `ThreadLocalEnv_test` 3 条（deadline / 函数表基址 / helper 栈），并做变异验证 |
| P3.1 | 删 `JitFunction.callMtx`；`callForFn` 改读本次调用的 `CallOut.escaped`，`lastEscaped` 只留作单线程诊断访问器 |
| P3.2 | `ParallelCall_test`（6 条）在**真实并发**下跑通，连续 3 轮无失败；`CallForFnConcurrency_test` 2/2 |
| P4.1 | 包装「A 创建 → B/C 调用 → D 释放」：`ParallelCall_test.wrapperCreatedOnOneThreadIsCallableFromOthers` 扩展为异线程 `close()` |
| P4.2 | `PromotionGroup` 全方法加锁（`add/release/contains/size/snapshot/releaseAll`），新增单热槽 4 线程 × 2000 次释放用例 |
| P5.1 | `state/active` 由单元 `mtx` 保证（`close` 置 state=1 → 轮询 active==0 → 终态；超时回退 state=0）；未改原子，留作 P6 性能项 |
| P5.2 | 新增 `UnloadConcurrency_test` 2 条：4 线程在飞时 `close` 排空并拒新（19）；`close(0)` 超时回退后单元仍可用；连续 3 轮稳定 |
| P1.2d | `freeSlots` 争用评估：4 线程基准 2.40× ⇒ 未成瓶颈，保持全局短锁（决策写入 tasks/design） |
| P1.5 | `NativeMem.malloc/freeCount` 改 `AtomicInt64`；并发调用后 `outstanding()` 回基线 |
| P6.1/6.3 | 全量 1188/1188；`liveCount` 与 `NativeMem.outstanding()` 均回基线 |
| P6.2 | `ParallelThroughput_test` 打印 1/2/4/8 线程实测（不设门槛，避免共享 VM 假失败） |
| P6.4 | README / README_en 新增并发 Q8；design 状态与 spec 措辞同步 |

## 关键实现决策（与设计文档的差异）

1. **窗口槽不要求索引连续**。运行期没有任何 helper 用 `hwBase/hwTop` 反推槽地址（已逐点核对：
   只有 `Helpers.hwCheck` 用 `capacityLimit - windowBaseOf()` 做容量账）。因此窗口槽可以来自共享
   空闲表；`resetWindow` 按「本窗口登记且 gen 仍匹配」逐槽释放。
   - 好处：保留「回收后复用同一槽」的既有语义（`AnyHostCast_test` 断言 1000 次循环后
     `slotCount == base + 1`），也避免连续区间被逃逸槽切碎后的碎片化。
   - 规格措辞已同步澄清为「一组互不重叠的槽（允许复用空闲槽，不要求索引连续）」。
2. **窗口收尾只释放路径 C（`append`）**。路径 B 的 `pin` 是桥侧资产、跨调用存活
   （`HandleTableM2_test.appendHostObjectDiffersOnlyInWindow` 明确断言），由 `CallMarshal.cleanup`
   或宿主释放；窗口 `pins` 清单只用于本窗口去重。
3. **登记存 ID（含 gen）而非索引**。`CallMarshal.cleanup` 可能先归还、槽可能被别的线程复用；
   收尾按索引盲放会误杀新槽（见下方变异 3）。
4. **JitExecutor 的函数表基址改为保存/恢复**：`invokeOff` 进入时记下本线程旧值，`finally` 恢复；
   这样宿主闭包重入时外层单元的表基址不会被内层清掉（旧实现直接 `reset()` 为 0）。

## 变异验证（证明用例真的能红）

| 变异 | 结果 |
| --- | --- |
| `IterTable.state()` 改回全局单例 | `iterTablesAreThreadPrivate` **FAILED**：主线程 `liveCount` left=1 / right=0 |
| 窗口栈改回全局单例 | `concurrentWindowsKeepSeparateAccounting` **FAILED**：`x.get()` left=131000 / right=0 |
| `resetWindow` 去掉 gen 校验（按索引释放） | `resetWindowDoesNotKillSlotReusedByAnotherThread` **FAILED**：`isLiveHandle(bId)` left=false / right=true |
| deadline/fnTableBase/helper 栈三处 TLS 同时改回全局 | `deadlineIsThreadLocal`、`fnTableBaseIsThreadLocal`、`userHelperStackIsThreadLocal` **三条全 FAILED** |
| `PromotionGroup.release` 去掉锁 | `concurrentReleasesDropRefcountExactly` **连续 3 轮全 FAILED**：`g.size()` left=1 / right=0（丢一次 −1 即泄漏） |

五次变异均已回滚；回滚后全量 1181/1181（P1）、1184/1184（P2/P3）、1185/1185（P4）。
P5 的两条用例未做变异（生命周期语义由既有 `close` 状态机保证，测试覆盖其可观察结果）。

## 并行吞吐实测（P6.2）

`ParallelThroughput_test`（2M 次循环的解释器单元；单次调用约 734 ms）：

| 线程数 | 墙钟 | 加速比 |
| --- | --- | --- |
| 1 | 734 ms | 1.00× |
| 2 | 1154 ms | 1.27× |
| 4 | 1220 ms | 2.40× |
| 8 | 3061 ms | 1.91× |

构建机为共享融合 VM（7 核、常驻负载 3+），8 线程已超订，故未达设计目标「8 线程 ≥5×」。
4 线程 2.40× 已证明**执行真正重叠**（删锁前恒为 1×）。达标复测需在专用 8 核机器上执行同一用例。

## 未完成 / 风险

- **P1.2d**：`freeSlots` 仍是全局 `ArrayList` + `mtx`（只保护分配/回收，临界区短）。
  并行度证据要等 P3 删 `callMtx` 后的 P6 基准；若分配成为瓶颈再切片私有化。
- **P1.5**：`NativeMem.mallocCount/freeCount` 仍为普通静态计数（诊断口径）。
- **吞吐目标**：共享 VM 上 8 线程 1.91×，未达 5×；需专用 8 核复测（见上表）。
- **端到端 deadline 隔离**：环境层 TLS 已测；「A 带期限、B 长调用并行」未单独覆盖，建议后续补一条时序用例。
- **API 命名漂移（本变更已按代码写口径）**：本变更的 delta 与用例统一使用 `close(timeoutMs)` / `close()`；
  主规格 `f-jit-facade-bridge` 中旧的 `unloadFn` 要求仍待单独立项对齐（不在本变更范围）。
- `resetForTest` 只清当前线程的窗口栈；其它线程的 TLS 无法追溯（测试线程均已 join，风险可接受）。

## 验证命令

```text
openspec validate feat-f-jit-parallel-call --strict
```
