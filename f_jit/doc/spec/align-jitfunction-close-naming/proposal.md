# Proposal

## Why

`JitFunction` 的释放 API 经历过两次改名：2026-10-24 `close` → `unloadFn`（归档变更
`refine-f-jit-unload-api`），随后 `jit-function-resource-close`（提交 `5c5dfb6ec`）让
`JitFunction` 实现 `std.core.Resource`，API 定稿为 `close(timeoutMs): Bool` / `close(): Unit` /
`isClosed(): Bool`。

主规格 `f-jit-facade-bridge` 没有跟随第二次改名：仍写着 3 处 `unloadFn` 与 1 处 `unload()`，
而同一文件里新归档的并发要求已经使用 `close`。结果是规格描述的方法在代码中不存在——按规格
写代码会编译失败，测试也无法与规格逐条对应。

## What Changes

- 「统一调用包装」要求按当前代码改写为 `close` 口径：`close(timeoutMs)` 统一释放入口与包装，
  `close()` 等价 `close(0)`，`isClosed()` 为方法；入口实例的 `close` 是**单元卸载**，不再是
  「入口调用 `unloadFn` → 19」。
- 相关场景改名：`close 协议`、`callForFn 并发`、`卸载逐出缓存`。
- 历史归档（`refine-f-jit-unload-api`、`jit-closure-unload-cascade`）与 M1 历史设计文档保留
  旧名，不回改——它们是当时的过程记录。
- **不改代码**，无行为变更。

## Capabilities

### Modified Capabilities

- `f-jit-facade-bridge`：`统一调用包装`（释放入口命名与入口/包装语义按 `Resource` 的 `close` 收口）。

## Impact

- 规格与实现、测试重新一致；无 API 变更、无性能影响。
- 后续如重新引入 `unloadFn`，必须单独立项并说明与 `Resource.close` 的关系。
