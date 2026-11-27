# 任务：fix-compile-failure-cache-sticky

- [x] T1.1 新增 `src/CompileFailureCache_test.cj`：① 未注册类失败 → 注册 → 同源码编译成功；② 300 个不同失败源码后 `failureCount() <= 256`。
- [x] T1.2 在**未改动**实现上跑：两条都必须红。
- [x] T2.1 `CompileCache.invalidateFailures()` + `failureCount()`；`fail()` 实施上限 256。
- [x] T2.2 五个注册入口（`registerFunction` / `unregisterFunction` / `registerClass` / `registerType` / `registerInterface`）在 `this.mtx` 内调用 `invalidateFailures()`。
- [x] T3.1 两条护栏转绿；`CompileCache_test` / `CompileAwaitTimeout_test` / `CompilerRegistrationConcurrency_test` 仍绿。
- [x] T3.2 全量零失败。
- [x] T4.1 `verify.md`（改前红两处）；T4.2 镜像；T4.3 归档 + 提交。
