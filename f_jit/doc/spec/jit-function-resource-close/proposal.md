# Proposal

## Why

`JitFunction` 是典型的可关闭资源（持有代码内存、常量句柄、逃逸闭包提升组），但未实现 `std.core.Resource`：无法用于 `try-with-resource`，也无法与 fountain 内其它资源（`Store` / `HttpClient` / `IoUring` …，均 `<: Resource`）统一管理。同时释放入口刚收敛为 `unload`，与全仓资源 API（`close()` / `isClosed()`）不一致；`isClosed` 还是「包装专属」属性，入口实例没有公开的已关闭标记。

## What Changes

- **BREAKING** `JitFunction <: std.core.Resource`：`close(): Unit`（不等待，等价 `close(0)` 丢弃结果）、`isClosed(): Bool`。
- **BREAKING** `unload(timeoutMs): Bool` → `close(timeoutMs): Bool`；`unload()` 移除；`isUnloaded()` 移除（由 `isClosed()` 取代）。
- **BREAKING** `prop isClosed` → `func isClosed()`：入口实例 = 单元已卸载（`state==2`），包装实例 = 本闭包已释放（含级联）。
- 仓内全部调用点改为 `close(...)` / `isClosed()`；`unloadFn` 保持 private。

## Capabilities

### Modified Capabilities

- `f-jit-facade-bridge`: 释放入口由 `unload` 改为 `close` 并实现 `Resource`；`isClosed()` 语义覆盖入口与包装两种实例。

## Impact

- 破坏性：`unload` / `isUnloaded` / `prop isClosed` 全部失效（仓外调用方编译错误）。
- 行为不变：级联释放、排空、超时回退、弱语义、缓存逐出不改。
- 文档：`f_jit/README.md` / `README_en.md`、`doc/design-m2.md`、`doc/jit-bytecode-m2.md`。
