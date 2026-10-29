# Tasks

> 全程 TDD：每个 C\*.1 先写失败用例并**实测红态**，再进实现。

## C1 逃逸闭包登记（条目模型）+ 单元终态级联

- [x] C1.1（Red）`unitUnloadReleasesEscapedClosures` —— 红态实测 8/8 全红（`unloadTimeoutRollbackKeepsClosures` 等一并红）。
- [x] C1.2（Red）`unwrappedClosureGroupIsSweptOnUnitUnload`（B1）。
- [x] C1.3 新增 `EscapedClosure.cj`（`seq` + 组 + `state` + `active`）；`JitFunction` 加 `escaped` / `escapedSeq` / `lastEscaped`，注册点落在 `callLocked` 解包 `retType=12`。
- [x] C1.4 单元终态：锁内标记条目 + 拷组 + 清表 + 取走 `release`；锁外先逐组 `releaseAll()`、再 `release()`。
- [x] C1.5 `cascadeThenWrapperUnloadIsIdempotent` / `unitUnloadCascadeKeepsOtherUnitsIntact` 绿。
- [x] C1.6 `unloadTimeoutRollbackKeepsClosures` 绿（在飞回调内 `unload(0)` → `false`，闭包不受影响）。

## C2 释放入口收敛 + 闭包级排空（B2）

- [x] C2.1 `wrapperUnloadOnlyReleasesOwnGroup` 绿（单元仍可调用、`CompileCache.runs()` 仍为 1）。
- [x] C2.2 `wrapperUnloadWaitsForInFlightCall` 绿（宿主回调内 `unload(0)` → `false` 且 `isClosed` 假；调用返回后 `unload()` → `true`，句柄回基线）。
- [x] C2.3 `unloadFn(timeoutMs): Bool` 转 private；`unload()` 按 `owner` 分派；单元侧 `enterClosure` / `exitClosure` / `unloadClosure` 单锁状态机；包装实例只挂条目。
- [x] C2.4 `isClosed` / `isUnloaded()` 从条目状态派生；`wrapperStatePredicatesAgree` 绿。
- [x] C2.5 用例迁移：删除 `unloadFnOnEntryInstanceIsRejected`（改为入口实例 `unload()` 的单元级断言）；20 处 `unloadFn()` → `unload()`；`staleClosureIdIsRejected` 改传条目。
- [x] C2.6 `grep unloadFn`：源码只剩 private 实现（`JitFunction.cj:274`），测试与 README 无旧名。

## C3 文档与规格同步

- [x] C3.1 `README.md` / `README_en.md`：示例、API 表、FAQ 表（驻留口径改为「单元终态级联」）、已知限制。
- [x] C3.2 `doc/design-m2.md` §6.1.4 成员表（`unload(timeoutMs): Bool` + 级联）。
- [x] C3.3 `doc/jit-bytecode-m2.md` §14.2 释放链（产生处登记 + 终态级联 + 超时回退不级联）。
- [x] C3.4 四件套落盘 `f_jit/doc/spec/jit-closure-unload-cascade/`。

## C4 回归与验收

- [x] C4.1 `f_jit` 全量 `cjpm test`：**1152 / 1152 PASSED，0 FAILED，0 ERROR**（含 8 条新增用例）。
- [x] C4.2 `grep fountain::f_jit`：无其它模块依赖（0 命中）。
- [x] C4.3 `openspec validate jit-closure-unload-cascade --strict`：valid。
- [x] C4.4 verify 回退路径（validate + 三对齐）：design 决定逐条有代码落点；tasks 全部有对应用例；delta 的每个 scenario 有验收用例或既有回归覆盖。
- [ ] C4.5 归档 `openspec archive`，用最终版覆盖 `f_jit/doc/spec/jit-closure-unload-cascade/`。
