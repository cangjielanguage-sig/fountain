# Verify

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线 | 1172 用例 / 1172 通过 / 0 失败 |
| 终态 | **1178 用例 / 1178 通过 / 0 失败 / 0 error / 0 skipped**（4m14s） |
| 新增 | 6 条（`ParallelCall_test`） |
| 回归 | 0 |

## TDD：先证「能红」，再证「能绿」

本套是**既有语义的回归网**（当前 `call` 由 `callMtx` 串行，并发等价串行），首次运行即绿——
所以额外做了**变异验证**，确认它真的能抓住它声称要抓的缺陷：

| 变异 | 结果 |
| --- | --- |
| 注释掉 `JitFunction` 收尾的 `HandleTable.resetWindow(-1)` | `concurrentCallsDoNotLeakHandles` **FAILED**：`liveCount` left=401 / right=1（4 线程 × 100 次调用泄漏 400 槽） |
| 恢复后重跑 | 6/6 通过 |

若没有这次变异，这条用例只是「跑了一遍没报错」，无法证明它会失败。

## 各条用例钉住的行为

| 用例 | 断言 | 当前为何能绿 | 并行化后必须保持 |
| --- | --- | --- | --- |
| `sameUnitConcurrentCallsAreCorrect` | 4×200 次返回值 = `base+i+1`；`isJitBacked` | 串行执行 | 同 |
| `concurrentCallsKeepErrorCodes` | 每线程错误码 = 1 | 串行；错误槽不被覆盖 | 并行下错误槽不得交错 |
| `concurrentCallsDoNotLeakHandles` | `liveCount` == 预热基线 | 窗口每调用归还 | 切片归还后仍相等 |
| `differentUnitsRunConcurrently` | 两单元各自结果正确 | 串行 | 单元间无串扰 |
| `wrapperCreatedOnOneThreadIsCallableFromOthers` | B/C 调用正确；`close()` 后 19（site=−1） | `callMtx` 不区分线程 | 包装跨线程仍有效 |
| `closedUnitRejectsConcurrentCalls` | 两线程均 19（site=−1） | 终态判断在锁内 | 终态对所有线程一致 |

## 执行中发现的分支漂移（重要，需回写规格）

测试第一版按归档规格调用 `unloadFn()` / `unload()`，编译失败：当前分支的 `JitFunction` 已被并行改动为

- **`close(timeoutMs): Bool`**：包装实例 → 释放该闭包；入口实例 → 单元终态（排空 + 逐出缓存 + 级联释放逃逸闭包）；
- **`close(): Unit`** = `close(0)`；`isClosed()` 为方法（非 prop）。

即 `unloadFn` 被移除、`unload` 与 `close` 重新统一。这**与 `f-jit-facade-bridge` 主规格的「`unloadFn()` 为唯一释放路径」冲突**，
也与 `doc/design-parallel-call.md` 的 `unload`/`unloadFn` 命名冲突。本变更只按当前代码写测试，不改规格与设计文档——
**漂移需单独立项对齐**（记录于本文件，供后续变更引用）。

## 未纳入本套

- 并行度证据（重叠执行）：当前必然失败，属 `feat-f-jit-parallel-call` P6.2 基准；
- deadline 线程隔离：当前存在跨线程串味（全局 `RuntimeEnv.deadlineNanos` 写在锁外），属该变更 P2.2。

## 归档

| 项 | 结果 |
| --- | --- |
| 命令 | `openspec archive test-f-jit-parallel-calls --yes` |
| 增量应用 | **+0 / ~0 / −0**（`skip_specs: true`，纯测试变更） |
| 归档路径 | `openspec/changes/archive/2026-11-26-test-f-jit-parallel-calls/` |
