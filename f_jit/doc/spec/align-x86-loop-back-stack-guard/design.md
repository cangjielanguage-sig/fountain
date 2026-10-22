# Design：x86_64 回边 STACK_GUARD（与 A64 的 frame 语义对齐）

## 1. 两侧 `frame` 的语义（先对齐，再写公式）

| 项 | aarch64 | x86_64 |
|---|---|---|
| 定义 | `A64Compiler.frameSize = align16(40 + 8*(nLocals + maxStack + 1))` | `BackendX86_64.frameSize = align16(32 + 8*(nLocals + maxStack + 1))` |
| 序言 | `sub sp, sp, frame`（`x31` 上的减法在该编码中不落实，真实 `sp` 仍在帧顶附近）；另设 **操作数指针 `x20` = `fp - (40 + 8*nLocals)`** | `push rbp; mov rbp,rsp; sub rsp, frame` ⇒ `rsp = rbp - frame`（帧底），操作数栈即 `rsp` |
| 回边表达式 | `r11 = (fp - frame) - sp`；`cmp r11, frame`；`b.lo deopt` | 待实现 |
| 正常回边的值 | **负**（`sp` 在帧底之上）⇒ 无符号比较下"低于"为假 ⇒ **不 deopt** | `0`（`rsp` 就在帧底）；随压栈向下增大 |
| 实际语义 | 仅在"溢出保留区达一个全帧"时才可能触发 | 同一语义需显式写成 `overflow >= frame` |

**结论**：`frame` 两侧都指**全帧尺寸**（不是 `maxStack`）；A64 因 `x20`/`sp` 分离而把守卫退化为
"几乎不触发"，x86 因 `rsp` 兼作操作数栈指针而必须**显式**比较 `overflow` 与 `frame`。

## 2. 实现（`X86Lower.cj` 的 `case 0x74u8`）

```
seq += 1
frame = BackendX86_64.frameSize(nLocals, maxStack)     // 与序言同值
mov  rax, rbp                                          // rax = 帧指针
mov  rdx, frame
sub  rax, rdx                                          // rax = rbp - frame（帧底）
sub  rax, rsp                                          // rax = 溢出量 overflow
mov  rdx, frame
cmp  rax, rdx                                          // 48 39 D0
jb   ok                                                // 0F 82：overflow < frame ⇒ 安全
mov  qword [r15+0], -1                                 // deopt
jmp  epilogue                                          // 不走 checkfail（-1 不转储）
ok:
call h_dispatch(22, ctx, null, 0)                      // H22 interrupt_poll（变体 0）
add  rsp, 8                                            // 丢弃占位，保持栈平衡
jmp  L<next+rel>                                       // 原回边跳转
```

要点：

- **方向**：`jb ok`（低于才继续）。上一轮误写 `jge ok` ⇒ 每个回边都 deopt（长循环退化为解释器、超时）；
- **不转储**：`-1` 直接 `jmp epilogue`，与 `bail(k ≤ 0)` 的既有分派一致；
- **栈平衡**：H22 变体 0 会压入占位结果 ⇒ `add rsp, 8` 对冲；`depth` 同步 `-1`。

## 3. 不变项

字节码 / opcode / helper / 错误码 / aarch64 / 三引擎语义均不变；deopt 仍由桥透明重放。

## 4. 测试

- **机制护栏**：新增 `X86Lower_test` 断言——含回边的单元在 H22 调用前出现 `jb`（`0F 82`）且比较对象为
  `frameSize`；把方向改回 `jge`（`0F 8D`）时断言失败。
- **行为验证**：`p0_6_deadlineInterruptsLoop`（1e8 迭代）仍**毫秒级**完成（证明未退化）；
  `PerfCompare_test` 的 JIT 数字与上一轮同量级。
- **回归**：全量 **1098/1098**、差分 11 例全绿。

## 5. 风险

| 项 | 说明 |
|---|---|
| 方向写反 | 全循环退化 ⇒ `p0_6`/`PerfCompare` 立刻暴露（本轮已加字节级护栏） |
| 阈值选择 | `frame`（全帧）与 A64 一致；更保守的 `maxStack*8` 会改变语义，不采用 |
| 额外开销 | 每回边 4 条指令（减法/比较/跳转），可忽略 |
