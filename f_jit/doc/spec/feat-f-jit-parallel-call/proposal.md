# Proposal

## Why

现状：`JitFunction.call` 全程在**进程级** `callMtx` 内（`JitFunction.cj:49/150`），`JitExecutor.invoke` 另有 `envMtx`。串行的根因不是「不想并行」，而是**一张全局句柄表只有一个全局窗口**：两个调用同时 `openWindow` 会互相清窗。

目标场景：**编译一次 → 所有线程共享同一产物 → 并行执行、互不干扰 → 每个线程独立的调用上下文/栈空间**；且 `callForFn` 的闭包包装**可跨线程调用**。

## What Changes

- **句柄表保持单表**（不按线程分片）：窗口改为**每调用独占切片**，切片互不重叠；`ctx.hwBase/hwCap/hwTop` 从「镜像」变成真实分配依据。
- 删除 `JitFunction.callMtx` 与 `JitExecutor.envMtx`；并发调用真正并行。
- 线程私有：`deadline`、函数表基址、user-helper 表栈、窗口嵌套栈。
- 每次调用私有：`lastEscaped`（改为 `callForFn` 的返回值，不再是单元级字段）、`JitContext`、解释器栈。
- 生命周期：`state/active` 改原子；`unload` 等待**所有线程**在飞调用排空，语义不变。
- 常量与提升槽留在全局表 ⇒ **ID/gen 不变**的既有契约不动，跨线程包装因此可用。

## Capabilities

### Modified Capabilities

- `f-jit-runtime`：`句柄窗口只增不减与容量封顶`（窗口 = 每调用切片）、`逃逸区与窗口重置`（只清本切片）。

### Added Capabilities

- `f-jit-facade-bridge`：`并发调用与执行状态隔离`。

## Impact

- **语义**：并发不再串行；单线程结果/错误码/site 逐位不变；`unload`/`unloadFn` 语义不变。
- **性能**：N 线程接近 N 路并行（目标：8 线程 ≥ 5× 单线程吞吐）；单线程路径新增一次切片分配（短临界区）。
- **风险**：句柄存储的并发写、容量增长与活跃窗口的重叠、提升/释放的原子性。见 design 风险表。
- **必须一并改的全局点**：`IterTable`（全局锁 + 全局表，`next` 每次都加锁）、`JitContext` 静态计数。
- **不在本次范围**：编译管线本身并行化（已按指纹并行）、跨进程共享产物。
