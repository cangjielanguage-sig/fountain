# Proposal

## Why

现有 1145 条用例里，**没有一条并发调用同一个 `JitFunction`**（`CallForFnConcurrency_test` 只覆盖 `callForFn` 的提升组串行化）。而 `feat-f-jit-parallel-call` 会把调用从「全局串行」改成「每调用窗口切片」——调度模型变了，必须有一张回归网先钉住**并发下的语义正确性**，否则并行化落地时无法区分「本来就错」和「改坏了」。

本变更只加测试，不改生产代码。

## What Changes

新增 `f_jit/src/ParallelCall_test.cj`（6 条）：

| 用例 | 钉住什么 |
| --- | --- |
| `sameUnitConcurrentCallsAreCorrect` | 4 线程 × 200 次同单元调用，返回值逐次正确，且走机器码 |
| `concurrentCallsKeepErrorCodes` | 并发下错误码/site 与单线程一致（不因交错而串码） |
| `concurrentCallsDoNotLeakHandles` | 分配型单元并发调用后 `liveCount` 回到基线 |
| `differentUnitsRunConcurrently` | 不同单元同时调用互不干扰 |
| `wrapperCreatedOnOneThreadIsCallableFromOthers` | A 建包装 → B/C 调用 → `close()` → 19 |
| `closedUnitRejectsConcurrentCalls` | 卸载后并发调用全部 19（site=−1），不是部分成功 |

**不包含**并行度证据（重叠执行、deadline 线程隔离）——那两项当前必然失败，属 `feat-f-jit-parallel-call` 的验收（P2.2/P6.2），不放进回归网。

## Capabilities

纯测试变更，`skip_specs: true`（不改任何行为契约）。

## Impact

- **代码**：零生产代码改动，只加一个测试文件。
- **测试**：+6 条；全量从 1172 → 1178。
- **风险**：并发用例的稳定性（线程数与迭代次数取值见 design）。
