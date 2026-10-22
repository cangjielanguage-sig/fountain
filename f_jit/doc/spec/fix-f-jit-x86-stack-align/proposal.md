# Proposal：修复 x86_64 JIT 分支汇合后的栈对齐错误

## Why

`f_jit` 全量测试在 **Linux x86_64 真机**上有 3 例 **SIGSEGV**（1091 例中 1084 过、3 ERROR），
全部落在新特性 `CastOr`（`E as T ?? V`）的**运行期不命中**路径：

- `CastOr_test.downcastFallsBackOnMismatch`
- `CastOr_test.bareCastFailsWithBadCast`
- `CastOr_test.unknownClassNameUsesRuntimeCheck`

崩溃栈显示：`JitExecutor.invokeOffLocked` → JIT 机器码 → `CJ_MCC_N2CStub`，`addr: (nil)`。
同一批用例在 aarch64 上全绿（对方基线 1076/1076）⇒ **x86_64 专属缺陷**。

根因（已定位到代码）：`X86Lower` 用**线性** `depth` 计数器推导栈深度，而
`alignBeforeCall()` 用 `pad = (depth % 2) != 0` 决定是否补 8 字节做 16 字节对齐。
`lowerCastOr` 发射的 `JZ fail; LOADL tmp; JMP end; fail: <fallback>` 形态里，
fail 分支的**运行期深度为 0、线性深度为 1** ⇒ 奇偶取反 ⇒ helper 调用前 `rsp` 未对齐 ⇒
`@C` 入口内的对齐敏感代码段故障。

## What Changes

- **`X86Lower` 引入 CFG 化的逐指令入口深度**：JIT 前对字节码做一次控制流数据流分析，得到
  `depthAt[off]`；`lower()` 在每条指令前以该值设定 `this.depth`，**不再让深度跨标签线性漂移**。
- **新增栈效应表**（`pops/pushes`，按 opcode + 操作数）：供上述数据流使用；无法判定的指令
  ⇒ 保守放弃 JIT（整单元退回解释器），不生成可能错误的机器码。
- **分支汇合一致性校验**：同一字节码偏移从不同前驱到达时深度不一致 ⇒ 放弃 JIT（防御，
  不改变语义；与既有「任何失败退回解释器」一致）。
- **用例与断言**：把 3 个崩溃用例固化为回归断言（不崩、值/错误码正确），并补 2 个**同型**
  用例（表达式 `if` 的 else 分支内含 `argc = 1` helper；`while` 回边后调用 helper），
  加 **字节级**断言（汇合点后的 `sub rsp, 8` / `add rsp, 8` 配对与奇偶一致）。
- **文档同步**：`design-m1` §12.3/§12.4（x86 序言/降低）补「深度由 CFG 推导、对齐由该深度决定」
  的口径；`f_jit/doc/spec/f-jit-m1/verify.md` 记录本次回归与修复。

**不改**：字节码格式、opcode、helper 集合、错误码、aarch64 lowering（其不依赖 depth）、
三引擎语义。

## Capabilities

- **New Capabilities**：
  - `f-jit-backend` —— x86_64 机器码生成的**栈对齐与深度推导**契约（本次新增该 capability 的
    两个 Requirement：CFG 深度与 16 字节对齐、汇合不一致时退回解释器）。
- **Modified Capabilities**：无（OpenSpec 仓库尚无既有主规格；见 `openspec list --specs` 为空）。

## Impact

- 代码：`f_jit/src/backend/X86Lower.cj`（主体）、`f_jit/src/backend/X86Compiler.cj`（若需贯通
  预扫结果）、新增 `*_test.cj`（同包）；`A64Lower` 不动。
- 行为：**只影响「能否 JIT 与生成的对齐序列」**；语义不变（失败退回解释器，结果/错误码/site
  三引擎仍逐位一致）。
- 风险面：栈效应表若遗漏某 opcode，会导致该单元退回解释器（**性能退化而非错误**）；由
  「未识别 ⇒ 放弃 JIT」的保守策略兜底。
- 依赖：无新增依赖（不涉及 `f_data` / 新 helper）。
