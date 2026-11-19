# Proposal：修复 x86_64 上 strictFp ÷0 与回边安全点缺失

## Why

合入 `sts/1.3.x` 后 x86_64 真机全量有 **4 个长期 FAILED**（与栈对齐修复无关，修复前即存在）：

| 用例 | 期望 | 实际 |
|---|---|---|
| `defaultIsStrict` / `strictDivisionByZeroFails` / `strictFpIsPartOfCacheKey` | `1.0f64 / 0.0` 以 **1（DIV_ZERO）** 失败 | 返回 `+Inf`（无异常） |
| `p0_6_deadlineInterruptsLoop` | 到期 deadline 的百兆循环抛 `InterruptedException` | 跑完不中断 |

根因（已定位到代码）：

1. **`floatDivChk()` 跳转谓词写反**（`X86Lower.cj:479`）：`ucomisd` 后先发 `jnp`（**有序**即跳）⇒ 除数 `0.0` 时直接跳到除法，**零检查被跳过**；反汇编语义应为 `jp`（仅 NaN/无序跳过，有序再判 ZF）。
2. **x86 的 `LOOP_BACK`(0x74) 缺回边安全点**（`X86Lower.cj:1000–1002` 只有 `jmp`）：aarch64 同处有 **STACK_GUARD + H22 `interrupt_poll`**（`A64Lower.cj:359–369`），解释器同样在回边调 `INTERRUPT_POLL`（`Interp.cj:576–578`）⇒ x86 既不在回边轮询期限，也没有栈余量 deopt。

## What Changes

- `floatDivChk`：首个条件跳转由 `jnp`(0x8B) 改为 **`jp`(0x8A)**（仅无序跳过），零除数落 ZF ⇒ `bail(1)`。
- x86 `LOOP_BACK`：补齐 **STACK_GUARD**（`(rbp-frame)-rsp < frame` ⇒ 写 `errCode=-1` 并跳出口）+ **H22 `interrupt_poll`**（结果占位出栈），再跳回边目标——与 aarch64/解释器同语义。
- 用例：4 个既有失败用例即 RED，修复后转绿；补 1 条 `floatDivChk` 的字节级断言（首个条件跳转为 `0F 8A`）作为机制护栏。
- 文档：`jit-bytecode-m1.md` §12.4（x86 降低表）补「`FDIV_CHK` 谓词」与「`LOOP_BACK` = STACK_GUARD + H22」两条口径；`verify.md` 记录本轮回填。

**不改**：字节码格式、opcode、helper 集合、错误码、aarch64（其已正确）、三引擎语义。

## Capabilities

- **Modified Capabilities**：`f-jit-backend`（新增 2 条 Requirement：x86 `FDIV_CHK` 零检查、回边安全点语义）。

## Impact

- 代码：`f_jit/src/backend/X86Lower.cj`（两处）；测试 `X86Lower_test.cj`（1 条字节断言）。
- 行为：strictFp 下 ÷0 恢复报 1；回边轮询期限、栈余量不足时退化解解释器（既有纪律，语义不变）。
- 风险：回边新增两条检查 ≈ 十余条指令的循环开销；`PerfCompare` 复测留档。
