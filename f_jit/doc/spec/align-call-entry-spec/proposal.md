# Proposal

## Why

`feature/f_jit` 在 2026-10-22 的合入中把带选项入口从 `invoke<T>(args, options)` 改成了同名重载 `call<T>(args, options)`（无选项的 `call<T>(args)` 委托给它）。代码、用例、README 已同步，但主规格仍写着「`invoke<T>(args, options)` 为唯一带选项入口」——规格与实现漂移。

这条规格是 `close-f-jit-out-of-checklist-findings` 归档进去的；当时选 `invoke` 的理由是「不与既有 `call` 混淆」，实际落地后发现同名重载更自然：宿主的调用点只记一个名字，带不带选项由重载决定，且 `CallContext` 是 struct、无法用默认参数表达「可选」。

## What Changes

- 规格 `调用入口与选项` 改为：`call<T>(args, options: CallContext)` 为带选项入口，`call<T>(args)` 等价于 `call<T>(args, CallContext())`；**SHALL NOT 另立 `invoke`**；**SHALL NOT 引入 `tryInvoke`**（错误语义与 `call` 一致）。
- 用例口径同步：`a3_4_invokeMatchesCall` 改名为 `a3_4_callOverloadsAgree`，注释与局部变量去掉 `invoke` 字样（断言不变）。
- 纯规格对齐，不改实现：代码在合入时已完成改名。

## Capabilities

### Modified Capabilities

- `f-jit-facade-bridge`：`调用入口与选项` 的入口名从 `invoke` 改为 `call` 重载。

## Impact

- **代码**：零改动（本次只改规格与用例命名/注释）。
- **API**：`invoke` 已在合入时移除；这是对 0.x 的破坏性变更，已在合入提交中标注。本次把它写进规格，消除漂移。
- **测试**：`AnyBridgeCall_test.a3_4_*` 改名 + 注释；`JitBacked_test.defaultCtorAndCallOverload` 已覆盖双载重，不改。
- **不在本次范围**：`callForFn` 的入口形态、`RuntimeEnv` 的 deadline 栈。
