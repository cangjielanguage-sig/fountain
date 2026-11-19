# Spec Delta

## Purpose

补充 `f-jit-backend` 在 x86_64 上的两条语义要求：`FDIV_CHK` 的零除数检查、回边的安全点
（栈余量 deopt + 期限轮询）。两者在 aarch64 与解释器侧已成立，本变更使 x86_64 对齐。

## ADDED Requirements

### Requirement: x86_64 `FDIV_CHK` 必须对零除数失败

`FDIV_CHK`（opcode `0x44`）在 x86_64 上 SHALL 在除数为 `0.0` 时以 **1（`DIV_ZERO`）** 失败；
除数非零时 SHALL 照常计算，结果为 NaN（无序）时 SHALL NOT 误判为零。

#### Scenario: 严格模式下 ÷0

- **WHEN** 以 `strictFp = true`（缺省）编译并执行 `{ x: Float64 => 1.0f64 / x }`，实参 `0.0`
- **THEN** 调用抛出 `JitException`，`code == 1`
- **AND** 实参 `2.0` 时返回 `0.5`（不误拒）

#### Scenario: 非严格模式保持 IEEE

- **WHEN** 以 `strictFp = false` 编译同一源码，实参 `0.0`
- **THEN** 返回 `+Inf`，不抛异常
- **AND** 两种 `strictFp` 的产物在缓存中互不复用（键含该标记）

### Requirement: x86_64 回边是安全点（栈余量 + 期限轮询）

`LOOP_BACK`（opcode `0x74`）在 x86_64 上 SHALL 在跳转前完成两件事，与 aarch64/解释器一致：

1. **栈余量检查**：`(rbp - frameSize) - rsp < frameSize` 时写 `errCode = -1`（deopt）并返回，
   由桥透明重放解释器；
2. **期限轮询**：调用 H22 `interrupt_poll`；其结果非 0（如 `-2`）时按既有收敛块返回该码。

#### Scenario: 到期 deadline 中断长循环

- **WHEN** 以 `CallContext.deadline = Some(过去时刻)` 调用 `{ n: Int64 => while (i < n) { i = i + 1 }; i }`（`n` 极大）
- **THEN** 抛出 `InterruptedException`（`errCode = -2`），不是跑完返回

#### Scenario: 栈余量不足退化解解释器

- **WHEN** 深递归/大帧导致回边处余量不足
- **THEN** 该次调用以 `-1` 返回并透明重放解释器，结果/错误码/site 与纯解释一致
