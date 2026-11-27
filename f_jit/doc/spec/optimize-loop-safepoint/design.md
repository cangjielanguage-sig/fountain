# 设计：回边安全点按需发射

## 决策总览

| 编号 | 决策 | 理由 |
| --- | --- | --- |
| D1 | 用 `ctx.flags` bit3 表达「本次调用带 deadline」，**不扩 ctx 布局** | ctx 是 64 B 冻结 ABI（8 个 Int64 全满），`flags` 运行期恒 0、位域空闲 |
| D2 | **不做回边节流**（每 N 轮 poll 一次） | 节流会把中断延迟从 0.7 µs 放宽到 N×0.7 µs，是有语义代价的取舍；flags 方案在无期限时零成本、有期限时仍逐回边检查，**零让步** |
| D3 | 不做「ctx 存 deadline 时间戳 + 回边内联比较」 | 同样要扩布局，且带期限时回边要读时钟（`vDSO` 调用）；flags 方案在有期限时直接退回现有 H22 路径，改动面最小 |
| D4 | x86 回边**同构改造** | x86 回边同样无条件调 H22（`X86Lower.cj:1032`），问题一致；两边必须行为一致 |
| D5 | 不新增规格 requirement（`skip_specs`） | 无期限时 H22 无副作用，跳过它是等价实现；「回边带安全点」的规格表述仍成立 |

## D1：为什么是 `flags` bit3

`JitContext` 布局（`doc/jit-bytecode-m1.md` §1，64 B 冻结）：

```
off 0 errCode | 8 site | 16 hwBase | 24 hwCap | 32 hwTop | 40 fnId | 48 flags | 56 dbgBase
```

- 8 个字全满，没有空槽；扩到 72/80 B 要改 `SIZE_BYTES`/`WORD_COUNT`、所有偏移常量、
  以及两个后端里硬编码的 ctx 偏移 —— 收益不匹配风险。
- `flags` 目前只有常量定义（`STRICT_FP=1` 历史位、`TRACE=2`、`HAS_LOOP=4`），
  `JitContext.create` 实际写入的是 **0**（`p.write(6, 0)`），运行期无人读。
- 新增 `DEADLINE = 8`（bit3）与既有位不冲突，且语义自然：「本次调用的 flags」。

## D2/D3：为什么不是节流、也不是 ctx 存时间戳

| 方案 | 无期限时回边成本 | 有期限时中断延迟 | 改动面 |
| --- | --- | --- | --- |
| 现状 | 654 ns | ≤1 回边 | — |
| **本方案（flags）** | **约 2 ns（4 条指令）** | ≤1 回边（不变） | ctx 写 1 处 + 两个后端回边 |
| 节流 N=16 | 约 41 ns | ≤16 回边（≈10 µs） | 回边计数器 + 规格改「每回边」表述 |
| ctx 存时间戳 | 约 3 ns（要读时钟才知是否到期） | ≤1 回边 | 扩 ctx 布局 + 桥写字段 |

本方案在两个维度同时最优：**成本最低**且**语义零让步**。

## D4：发射序列

### AArch64（`A64Lower.cj` case `0x74`）

现状：

```
STACK_GUARD（mov/sub/movImm64/cmp/b.lo deopt）
helperCall0(22)          // movImm64 x0=22; mov x1=x19; mov x2=x31; movImm64 x3=0;
                         // movImm64 x9=dispatch; blr x9
b target
```

改为：

```
STACK_GUARD
ldr   x0, [x19, #48]     // ctx.flags
mov   x1, #8             // CtxFlags.DEADLINE
and   x0, x0, x1
cbz   x0, skip_poll      // 无期限 ⇒ 跳过
helperCall0(22)
skip_poll:
b target
```

常路径 = `ldr + mov + and + cbz + b` = 5 条（A53 上约 2–3 ns）。
用到的发射器方法均已存在：`ldrOff` / `movImm64` / `andReg` / `cbz` / `b`。

### x86-64（`X86Lower.cj` case `0x74`）

现状：`STACK_GUARD` → `helper(22, 0, 0)` → `add rsp,8` → `jmp`。

改为：

```
STACK_GUARD
mov   rax, [rdi+48]      // ctx.flags（x86 侧 ctx 在 rdi）
mov   rdx, 8
test  rax, rdx
jz    skip_poll
helper(22, 0, 0)
add   rsp, 8
skip_poll:
jmp   target
```

`jz` 用 `0F 84 rel32`（与既有 `rel32` + label 机制一致）。

## 等价性论证（为什么不需要改规格）

1. **无期限 ⇒ H22 是空操作**：`deadlineExpired()` 首行 `if (deadlineNanos < 0) return false`；
   `interruptPoll` 只在为真时 `ctxWriteCode(-2)`。跳过它不写 `errCode`、不设 `site`、不产生转储。
2. **deadline 在 ctx 生命周期内不变**：
   - `JitFunction.call` 先 `setDeadline(...)`，再 `callLocked` → `JitContext.create`，顺序保证读到的是本次调用的值；
   - 同一线程重入时，内层 `setDeadline` 覆盖、`finally` 恢复外层；内层 ctx 的 flags 反映内层语义
     （现状下内层每轮 poll 读的也是被内层覆盖后的 TLS，行为一致）；
   - 包装实例调用（`callForFn`）不重置 deadline，`create` 读到的仍是当时 TLS 值 —— 与现状一致。
3. **`flags` 只增一个位**：`HAS_LOOP`/`TRACE`/`STRICT_FP` 的读写方均不看 bit3。

## 风险与回退

| 风险 | 处置 |
| --- | --- |
| 未来出现「执行中途改 deadline」的用法 | 本优化假设 deadline 在 ctx 生命周期内固定；若需求出现，回退为无条件发射 |
| x86 侧无法在本机构建/运行验证 | 以「发射字节断言」+ 与 A64 同构代码审查兜底；`X86Lower_test` 若可跑则加用例 |
| `flags` 位被其它功能占用（历史位 STRICT_FP 曾计划运行期读） | 本次只用 bit3，若将来越界，需重新分配位域 |

## TDD 策略

- **Red（可观察行为）**：本次是**等价优化，没有行为 Red**（这是设计声明的 TDD 例外）。
  护栏用既有 `p0_6_deadlineInterruptsLoop`（**有期限必须中断**）+ 新增「无期限长循环跑完」。
- **守卫用例**：如果实现把「有期限也跳过 poll」，`p0_6` 必须变红 —— 用它做变异验证。
- **性能观测**：新增软观测（print 每轮 ns），**不设硬门槛**（共享 VM 噪声大，硬门槛会制造假失败）。
- 判定：性能观测需从约 660 ns/轮 降到 ≤ 60 ns/轮（内部目标），否则回滚。
