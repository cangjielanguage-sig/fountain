# 测试计划

基线：`e439a303` 归档后 **1137 / 1137 / 0 / 0**。

| 用例 | 断言 | 落点 |
| --- | --- | --- |
| `unloadFnIsIdempotentAndReleasesGroup`（改名自 `closeIsIdempotentAndReleasesGroup`） | 重复 `unloadFn` 幂等、提升槽归零、`isClosed` 转真、之后调用 19 | `JitFunctionClosure_test` |
| `unloadFnOnEntryInstanceIsRejected`（改名自 `closeOnEntryInstanceIsRejected`） | 入口实例 `unloadFn` → 19（site=−1）、`isClosed` 恒 false | `JitFunctionClosure_test` |
| `staleClosureIdIsRejected`（改调用） | `unloadFn` 后旧 ID 再包装 → 19 | `JitFunctionClosure_test` |
| `unloadEvictsUnitFromCache`（新） | 编译 → `runs()==1` → `unload()` → 同源再编译 → `runs()==2`、新单元可调用 | `refineUnload_test` |
| ~~`unloadTimeoutKeepsCacheEntry`~~（未自动化） | 需可控的在飞调用；改由代码结构保证（逐出只写在 `state=2` 分支），见 `verify.md` 已知边界 | — |
| 其余 16 处 `close()` 调用点（`Slot14_test` / `Q6Acceptance_test` / `CallForFnConcurrency_test`） | 仅改名，断言不变 | 同名文件 |

门槛：全量零失败；改名后错误消息与文档不得残留 `close()`（`grep` 口径排除历史归档与 `isClosed`）。
