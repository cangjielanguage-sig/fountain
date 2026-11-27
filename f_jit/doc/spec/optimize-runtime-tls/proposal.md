# 调用路径：线程私有运行期状态合并（TLS 访问 14 → 2 次）

## Why

`optimize-call-path.md` §12.4 曾把「剩余 8.6 µs/调用」归因于 GC 与 cache miss，并判定「需要 perf 才能继续」。
2026-11-27 的进程内探针（同轮配对、best-of-3，探针已删）推翻了这个判断：

| 测量 | 数据 |
| --- | --- |
| `ThreadLocal` 单次 `get` / `set` | **319 / 304 ns**（std 实现；私有实例 4T 503 vs 共享 508 ⇒ 不是实例争用） |
| `realTlsBundle`（deadline 保存/设置/恢复 + fnTable 保存/设置/恢复，6 次） | **1906 ns** |
| `windowBundle`（`openWindow` + `base` + `cap` + `resetWindow`，4 次 TLS + 2×`Win`） | **1888 ns** |
| `JitFunction.call` 全路径 TLS 访问 | **14 次**（deadline 3、fnTable 3、win 5、iter 1、fault 1） |
| 推算成本 / 占比 | **~4.4 µs / 8.6–9.7 µs（约 45–51%）** |

同一轮对照：GC 分配约 1.0–1.4 µs、`enter/exit` 两对 mutex 86 ns、NativeMem 两个原子无争用。
**TLS 访问是当前调用路径的第一大单项**，且每一项都是可以合并的重复读取。

## What Changes

把「调用级/线程级」的 5 份 TLS 状态合并进一个线程私有 `RuntimeState`，每次调用只取一次：

| 状态 | 现状 | 改后 |
| --- | --- | --- |
| `RuntimeEnv.deadlineNanos` | 独立 `ThreadLocal<Int64>` | `RuntimeState.deadlineNanos` 字段 |
| `MachineEnv.fnTableBase` | 独立 `ThreadLocal<Int64>` | `RuntimeState.fnTableBase` 字段 |
| `HandleTable` 窗口栈 | 独立 `ThreadLocal<ArrayList<Win>>` | `RuntimeState.wins` 字段 |
| `IterTable` 迭代器表 | 独立 `ThreadLocal<IterState>` | `RuntimeState.iters` 字段 |
| `HostFault` 异常旁路表 | 独立 `ThreadLocal<HashMap>` | `RuntimeState.faults` 字段（懒建） |

配套的**零 TLS 化**：

- `JitFunction.call` 开头取一次 `RuntimeEnv.current()`，之后所有状态都走该对象字段；
- `HandleTable` 新增 `openWindowWith(rs, cap) -> (base, cap)`、`resetWindow(rs, keep)`、
  `syncTo(ctx, rs)`，一次返回窗口上下界，不再分别 `windowBaseOf()`/`windowCapOf()`；
- `JitContext.create` 增加 `deadlineNanos!` 参数，由调用方传入，不再回读 TLS；
- `IterTable` / `HostFault` 改用 `ctx.flags` 的 `ITER` / `FAULT` 位门控：健康路径 0 次 TLS，
  只有真正用过迭代器/记录过异常才访问；
- `JitExecutor.invokeOff` 仅在 `fnTableBase` 实际变化时才 set/restore（稳态 3 次 → 1 次 get）；
- `JitFunction.call` 仅在 `deadline` 与当前值不同才写，无期限的常规调用 0 次写。

预期：**14 次 → 2 次**（`current()` 1 次 + `fnTableBase` get 1 次），
按 318 ns/次估算 **−3.8 µs（约 −40%）**。

**语义不变**（纯内部布局重构）：

- 所有状态仍然是**线程私有**：跨线程不共享、不串味（`ThreadLocalEnv_test` / `WindowIsolation_test` /
  `HostFaultTls_test` / `IterLifecycle_test` 继续作为护栏）；
- 重入（JIT → 宿主闭包 → 再进 JIT）仍按栈式保存/恢复 deadline 与 fnTable；
- 窗口开合、迭代器清理、异常 cause 的对外行为完全一致；
- 不新增/修改规格 requirement（`skip_specs: true`）。

## Impact

- 收益目标：`L1` 从 8.6–9.7 µs 降到 **≤6 µs**（≥30%），`Q1` 同比例提升；`Q4` 不回退；
- 影响文件：`src/runtime/RuntimeEnv.cj`、`JitContext.cj`、`HandleTable.cj`、`IterTable.cj`、
  `HostCall.cj`、`src/JitFunction.cj`、`src/backend/JitExecutor.cj`（+ 新增 `RuntimeState.cj`）；
- 风险：`Win` / `IterState` / `FaultEntry` 需从文件级 `private` 放宽到包级 `internal`（仍在模块内，
  用户面不可见）；`RuntimeState` 的初始化顺序与懒建语义必须与旧 TLS 逐项对齐。
- 判定：按 `optimize-call-path.md` §1 硬规则，5 次中位数 + MOV；达不到就回滚并记录数据。
