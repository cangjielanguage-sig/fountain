# Tasks

- [x] T1.1 红态基线：写 `sameUnitConcurrentCallsAreCorrect` 并运行，确认当前串行实现下为**绿**。**（首次 6/6 绿；另做变异验证：注释掉 `resetWindow` 后 `concurrentCallsDoNotLeakHandles` 必红，见 verify）**
- [x] T1.2 补齐 5 条：错误码、句柄账目、多单元、跨线程包装、卸载后并发。**（用例名按当前 API 改为 `closedUnitRejectsConcurrentCalls`）**
- [x] T1.3 全量 `cjpm test --parallel 1` 零失败；用例数 1172 → 1178。**（1178/1178/0/0，4m14s）**
- [x] T1.4 `verify.md`：每条用例钉住的行为、当前实现为何能绿、并行化后应保持。**（另记录分支 API 漂移：`unloadFn` → `close`）**
- [x] T1.5 归档 `openspec archive test-f-jit-parallel-calls --yes`，同步 `f_jit/doc/spec/` 镜像
