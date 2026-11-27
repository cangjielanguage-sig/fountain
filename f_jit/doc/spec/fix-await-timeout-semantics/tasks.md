# 任务：fix-await-timeout-semantics

- [x] T1.1 `CompileCache` 增加 `awaitTimeoutNs`（默认 30 s），`awaitReady` 改用它。
- [x] T1.2 `CompileCache` 增加 `isCompiling(key)`。
- [x] T1.3 `CompilePipeline.missingResult(key, fallback)` 三态判定；`runSource`/`runUnit` 的 `None` 分支改用它。
- [x] T1.4 新增 `CompileAwaitTimeout_test`：1 ms 超时路径 + 三态判定的直接断言。
- [x] T2.1 相关用例全绿；全量零失败。
- [x] T3.1 `verify.md`；T3.2 镜像；T3.3 归档 + 提交。
