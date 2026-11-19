# Proposal：x86_64 回边补 STACK_GUARD，并与 A64 的 frame 语义对齐

## Why

上一轮（`fix-f-jit-strictfp-deadline-x86`）给 x86 的 `LOOP_BACK` 补了 H22 期限轮询，但**栈余量守卫**仍是遗留项：

- aarch64：`A64Lower.cj:359–369` 在回边做 `(fp - frame) - sp` 与 `frame` 比较，低于则跳 `deopt`；
- x86：`X86Lower.cj` 的 `case 0x74u8` 仍只有 H22 + `jmp`。

首次尝试时把比较方向写成 `jge 继续`（溢出量 ≥ frame 才继续），导致**每个回边都 deopt**：
循环全部落回解释器，`p0_6_deadlineInterruptsLoop`（1e8 次迭代）等用例超时——即"方向反了"。
另外两侧 `frame` 的含义需先对齐，否则公式无法移植：

| 侧 | `frame` 含义 | 操作数栈 | 正常回边时的 `(帧底 - 当前栈顶)` |
|---|---|---|---|
| A64 | `frameSize = align16(40 + 8*(nLocals+maxStack+1))`（**全帧**） | **独立指针 x20**，真实 `sp` 恒在帧底附近 | **负值**（无符号巨大）⇒ 守卫不触发 |
| x86 | `frameSize = align16(32 + 8*(nLocals+maxStack+1))`（**全帧**） | `rsp` 本身从 `rbp-frame` 向下生长 | **0 起**的溢出量，可直接测 |

⇒ 共同语义是"**操作数栈溢出保留区达一个全帧 ⇒ deopt(-1)**"；A64 侧因 x20 与 sp 分离而退化为恒不触发，
x86 侧必须显式写成 `overshoot >= frame ⇒ deopt`，且**分支方向不能反**。

## What Changes

- `X86Lower` 的 `case 0x74u8` 在 H22 之前补 **STACK_GUARD**：
  `rax = (rbp - frame) - rsp`（overflow），`rdx = frame`，`cmp rax, rdx`，
  **`jb ok`（overflow < frame ⇒ 安全）**，否则 `mov qword [r15], -1` + `jmp epilogue`（deopt，不转储）。
- `frame` 取 `BackendX86_64.frameSize(nLocals, maxStack)`（与序言同一公式、同一值）。
- 文档：`jit-bytecode-m1.md` §12.4 把"x86 栈余量守卫为遗留项"改为**已实现**，并写清两侧 `frame` 语义对照；
  `verify.md` 记录本轮回填。

**不改**：字节码格式、opcode、helper、错误码、aarch64（其语义已定）、三引擎语义。

## Capabilities

- **Modified Capabilities**：`f-jit-backend`（新增 1 条 Requirement：x86 回边 STACK_GUARD 与 A64 的
  `frame` 语义对齐、方向不得反、deopt 不转储）。

## Impact

- 代码：`f_jit/src/backend/X86Lower.cj`（`case 0x74u8`，约 +14 行）。
- 行为：正常回边**不触发** deopt（多 4 条比较指令）；仅当操作数栈溢出超过一个全帧时以 `-1` 透明退回解释器。
- 风险：公式/方向写错会让所有循环退化为解释器（上一轮的教训）⇒ 用**循环密集型**用例（`p0_6`、
  `PerfCompare`）与全量 1098 例把关。
