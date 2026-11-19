# Proposal：x86 审计对称化（绝对地址例外）+ f_util 用例执行

## Why

对方提交 `d2b0b4d8`（A64 发射审计豁免宿主绝对地址）暴露了两件事：

1. **x86 侧存在同构但未覆盖的路径**：`PUSH_KH`（常量句柄）与 `CALL_FUNC`（fnTable）都把**宿主绝对地址**
   物化到寄存器后再解引用，而 x86 审计只登记自有发射器（`movRaxMemRsp`/`pushMemRbp` 等），
   这两条**完全不经过审计点**——当前是"漏审"（不会误判），但一旦收紧审计就会复现 A64 的整单元回退。
2. **`f_util` 的用例从未被执行**：`f_jit` 只把 `f_util` 当 path 依赖构建，`cjpm test` 不跑它的测试；
   而 `443f15e6` 恢复的 FNV 带着 **14 条** `@TestCase`，属"写了但没跑"。

## What Changes

- `BackendX86_64` 审计增**绝对地址例外**（哨兵 `-1`）：`noteAbsMem()` 显式登记，`auditAllows` 接受 `-1`；
  `X86Lower` 在 `PUSH_KH` 与 `callFunc` 的绝对地址解引用处登记（与 A64 的豁免规则对称）。
- 测试：
  - `EmitAudit_test` 增 `absoluteAddressIsExempt`（`auditAllows([-1])`、`noteAbsMem` 采集）；
  - 新增 `JitBacked_test`：含常量镜像的单元（字符串字面量 ⇒ `PUSH_KH`）必须 `isJitBacked() == true`
    ——防"审计收紧后整单元静默回退"。
- `f_util` 用例执行：在 WSL x86_64 跑 `cd f_util && cjpm test`，把结果记入 `verify.md`
  （仓库无 CI 配置，暂以"记录 + 可复跑命令"作为门禁）。

**不改**：`.fbc` 格式、opcode、helper、错误码、aarch64（其豁免已由对方提交落地）、三引擎语义。

## Capabilities

- **Modified Capabilities**：`f-jit-backend`（新增 1 条 Requirement：x86 审计的绝对地址例外与 A64 对称）。

## Impact

- 代码：`f_jit/src/backend/BackendSelector.cj`（哨兵与判定）、`X86Lower.cj`（两处登记）；
  测试：`EmitAudit_test.cj`（+1 例）、新增 `JitBacked_test.cj`（2 例）。
- 风险：哨兵 `-1` 只影响测试期的审计集合；生产语义不变（`auditAllows` 仍会拒绝真正越界的基址）。
