# 回边安全点改为「按需」：无期限调用跳过 `interrupt_poll`

## Why

`doc/optimize-call-path.md` §14 的实测（aarch64）：

| 配置 | 每轮 |
| --- | --- |
| 机器码，含回边 poll | **658 / 665 / 662 ns** |
| 机器码，去掉回边 poll（发射端变异） | **15 / 15 ns** |

回边 `interrupt_poll`（H22）占空循环 **97.7%**。原因是每个回边都要：

- 物化 `hid`、`argc`、**`helperDispatch` 绝对地址**（`movImm64` 共 3 次）；
- `blr` 进 `invokeHelper`：`try/catch` + `match(hid)`（100+ 分支）+ `interruptPoll`；
- `interruptPoll` 读线程本地 `deadlineNanos`。

而 `interrupt_poll` 在**无期限**时是有副作用的空操作：

```cj
public static func deadlineExpired(): Bool {
    if (deadlineNanos < 0) { false }   // 首行短路，连时钟都不读
    else { nowNanos() >= deadlineNanos }
}
```

绝大多数调用不带 deadline（`CallContext.deadline = None`），却为每个回边付 654 ns。

## What Changes

把回边序列从「无条件调 H22」改为「**仅当本次调用带 deadline 时才调**」：

1. `CtxFlags` 增 `DEADLINE = 8`（bit3，`flags` 字段当前运行期恒 0，位域空闲）；
2. `JitContext.create` 按 `RuntimeEnv.deadlineNanos >= 0` 写该位；
3. A64 回边：`ldr flags → and DEADLINE → cbz 跳过 → helperCall0(22)`；
4. X86 回边：同构（`mov rax,[rdi+48] / test rax,8 / jz 跳过 / call H22`）。

## 为什么这是等价优化（不是语义变更）

- 无期限时 `interrupt_poll` 恒返回 0、**不写 `errCode`、不设 `site`** ⇒ 跳过它不改变任何可观察结果；
- 有期限时**仍然每回边检查**，中断延迟不变（不引入节流放宽）；
- `deadline` 在 ctx 生命周期内不变：桥在 `call` 入口写线程 TLS（`saved → set → finally 恢复`），
  ctx 随后由 `callLocked` 创建；嵌套调用各自覆盖 TLS 并各自创建 ctx。
- 因此不新增/不修改规格 requirement（`skip_specs: true`），只更新实现与权威文档的发射描述。

## 影响面

- 收益：紧循环从 662 → 约 17 ns/轮（**约 39×**）；只影响**执行期**，编译产物字节变短；
- 风险：若未来出现「调用执行中途修改 deadline」的需求，本优化必须回退（当前架构不支持这种用法）；
- 兼容：`flags` 位域新增 bit3，旧读者不读该位；`HAS_LOOP`（bit2）仍未被写入，本次不动。

## 验收

- **关键回归**：`AnyBridgeCall_test.p0_6_deadlineInterruptsLoop`（过期 deadline 在回边返回 −2）必须继续通过；
- 新增：无期限长循环正常跑完；有期限长循环可被中断；
- 性能观测：空循环每轮 ns（打印，不设门槛）；
- 全量零失败。
