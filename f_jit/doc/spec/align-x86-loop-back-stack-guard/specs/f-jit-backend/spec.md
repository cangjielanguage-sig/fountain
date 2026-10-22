# Spec Delta

## Purpose

补齐 x86_64 回边（`LOOP_BACK`）的**栈余量守卫**，并与 aarch64 的 `frame` 语义对齐：两侧都以
「操作数栈溢出保留区达一个**全帧**（`frameSize(nLocals, maxStack)`）⇒ deopt(-1)」为准。

## ADDED Requirements

### Requirement: x86_64 回边的栈余量守卫与 aarch64 的 frame 语义对齐

`LOOP_BACK`（opcode `0x74`）在 x86_64 上 SHALL 在 H22 `interrupt_poll` **之前**做栈余量检查：

- 溢出量 `overflow = (rbp - frame) - rsp`，其中 `frame = frameSize(nLocals, maxStack)`（**全帧**，
  与序言 `sub rsp, FRAME` 同一值）；
- `overflow < frame` ⇒ 继续（正常路径，**SHALL NOT** deopt）；
- `overflow >= frame` ⇒ 写 `errCode = -1` 并直接返回（`jmp epilogue`，**SHALL NOT** 走 `checkfail`
  转储块；由桥透明重放解释器）。

条件跳转方向 SHALL 与上述语义一致（"低于阈值才继续"），不得反向——方向反了会使**每个回边**都
退化解解释器（循环性能塌陷为解释器，长循环用例超时）。

#### Scenario: 正常回边不退化

- **WHEN** 执行循环密集型单元（如 `{ n: Int64 => while (i < n) { i = i + 1 }; i }`，`n = 1e8`）
- **THEN** 该单元在 JIT 内完成（不因 STACK_GUARD 退化），且 `PerfCompare_test` 的 JIT 数字与
  修复前同量级（波动在噪声内）

#### Scenario: 溢出超过全帧才 deopt

- **WHEN** 操作数栈溢出保留区超过一个 `frameSize`（构造性/极端深度表达式）
- **THEN** 以 `-1` 返回并透明重放解释器，结果 / 错误码 / site 与纯解释一致
- **AND** 该次调用**不产生** `jit_dump` 转储（`-1` 不转储）

#### Scenario: 两架构语义一致

- **WHEN** 同一单元在 x86_64 与 aarch64 上执行（含 `p0_6_deadlineInterruptsLoop`）
- **THEN** 结果 / 错误码 / site / 报告文本逐位一致（I7 不变）
