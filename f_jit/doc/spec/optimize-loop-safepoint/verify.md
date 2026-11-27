# Verify：回边安全点按需发射（`optimize-loop-safepoint`）

## 变更范围

| 项 | 内容 |
| --- | --- |
| `CtxFlags.DEADLINE` | `bit3`（`8`），表示「本次调用带 deadline」 |
| `JitContext.create` | 按 `RuntimeEnv.deadlineNanos >= 0` 写 `flags`（原为恒 0） |
| AArch64 回边 | `ldr flags → and 8 → cbz 跳过 → helperCall0(22)` |
| x86 回边 | `mov rax,[r15+48] → test rax,8 → jz 跳过 → call H22` |
| 规格 delta | **无**（`skip_specs: true`）：无期限时 `interrupt_poll` 无副作用，跳过是等价实现 |

## 数据

| 指标 | 改动前 | 改动后 | 说明 |
| --- | --- | --- | --- |
| 空循环每轮（`LoopSafepoint_test.loopPerIterCost`） | **665 ns** | **15 ns** | **44×**；best-of-3，断言返回 `n` |
| 与 §14 基线一致性 | 665（本次） vs 658/665/662（§14） | — | 同量级，基线可信 |

## 语义验证

| 用例 | 作用 | 结果 |
| --- | --- | --- |
| `LoopSafepoint_test.unboundedLoopRunsToCompletion` | 无期限长循环跑完、`deadlineNanos` 仍为 −1 | 绿 |
| `LoopSafepoint_test.boundedLoopStillInterrupts` | 过期 deadline ⇒ 紧循环抛 `InterruptedException` | 绿 |
| `AnyBridgeCall_test.p0_6_deadlineInterruptsLoop`（既有） | 同样语义的端到端锁 | 绿（7/7） |
| `X86Lower_test.loopBackPollGate`（新增） | x86 发射字节：`498B4730` / `BA08000000` / `4885D0` / `0F84…` | 绿（50/50） |

## 变异验证（硬要求）

把回边的 `cbz(0, skipPoll)` 临时改为 `b(skipPoll)`（**无条件跳过** poll）：

| 用例 | 结果 |
| --- | --- |
| `LoopSafepoint_test.boundedLoopStillInterrupts` | **FAILED**（164 ms 后返回 n，未中断） |
| `AnyBridgeCall_test.p0_6_deadlineInterruptsLoop` | **FAILED**（888 ms 后返回 n，未中断） |

两条护栏同时变红 ⇒ 用例真能捕获「误跳过安全点」。已恢复实现。

## 全量

| 轮次 | 结果 |
| --- | --- |
| 第 1 遍 | 1213 / 1214；唯一失败 `PerfM2_test.userHelperVsHostClosure`（比值用例，直接调 `invokeHelper`、不经回边，与本次无关），**单跑通过** |
| 第 2 遍 | **1214 / 1214 / 0 失败 / 0 error / 0 skipped** |

新增用例 4 条（`LoopSafepoint_test` 3 + `X86Lower_test.loopBackPollGate` 1）。

## 风险与遗留

- **deadline 固定性假设**：本优化假设一次调用内 `deadline` 不变（桥在 `call` 入口写入、ctx 随后创建；
  嵌套调用各自覆盖 TLS）。若未来支持「执行中途改 deadline」，必须回退为无条件发射。
- **x86 未在真机验证**：本机为 aarch64，x86 侧只做了字节级断言与同构代码审查；
  建议在 x86_64 机器上补一次 `LoopSafepoint_test` 冒烟。
- `PerfM2_test.userHelperVsHostClosure` 与已稳健化的 `PerfOverride_test` 同类（两臂比值、2000 轮），
  高负载下仍会偶发假失败；本次未改（超出范围），建议后续按同一模式改 best-of-3。

## 归档

`openspec archive optimize-loop-safepoint --yes` → `2026-11-27-optimize-loop-safepoint`。
