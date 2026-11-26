# Design

## D1 以代码为准，规格回退到 `close`

理由：

1. `JitFunction <: std.core.Resource` 是最后一次 API 决策（提交 `5c5dfb6ec`），`close()` /
   `isClosed()` 是 `Resource` 契约的一部分，不能删除；
2. 仓内调用点与测试已全部使用 `close`（`refineUnload_test`、`ParallelCall_test`、
   `JitFunctionClosure_test` 等）；
3. `unloadFn` 只是 2026-10-24 的中间态，仓内已无任何调用点。

## D2 历史归档不回改

`refine-f-jit-unload-api` 与 `jit-closure-unload-cascade` 的文档记录的是当时的决策与迁移面，
保留 `unloadFn`/`unload` 原名；只在**主规格**与**当前设计文档**（`design-m2.md`、
`design-parallel-call.md`）改为 `close`。

## D3 入口语义必须写清

旧文本「对入口实例 `unloadFn` → 19、`isClosed` 恒 false」是包装专用 API 的语义。改为 `close`
后入口实例的 `close(timeoutMs)` 是**单元卸载**：排空全部在飞调用、进入终态、逐出缓存；超时
回退可用并返回 `false`。`isClosed()` 对入口反映单元状态、对包装反映本闭包状态。

## D4 场景与验收入口

- `close 协议`：包装重复 `close()` 幂等；入口 `close(timeoutMs)` 排空后进终态，超时回退。
- `callForFn 并发`：两线程各自 `close()` 互不干扰。
- `卸载逐出缓存`：`close()` 成功后同源重编按未命中处理。

## 风险

- 主规格的「统一调用包装」正文超过 500 字符的严格校验警告是**既有的**（历史文本本就超长），
  本变更不新增阈值问题；`validate --all`（非 strict）9/9 通过。
