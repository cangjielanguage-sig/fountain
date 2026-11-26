# 测试计划

基线：f_jit 全量 **1172 / 1172 / 0**（`feat-f-jit-parallel-call` 设计归档后）。

| 用例 | 断言 | 说明 |
| --- | --- | --- |
| `sameUnitConcurrentCallsAreCorrect` | 4×200 次调用返回值 = `base+i+1`；`isJitBacked` | 主回归 |
| `concurrentCallsKeepErrorCodes` | 每线程错误码 = 1、site 一致 | 错误槽不被交错覆盖 |
| `concurrentCallsDoNotLeakHandles` | 并发后 `liveCount` == 预热后基线 | 窗口归还 |
| `differentUnitsRunConcurrently` | 两单元各自结果正确 | 单元间无串扰 |
| `wrapperCreatedOnOneThreadIsCallableFromOthers` | B/C 调用结果正确；`close()` 后调用 → 19 | 包装跨线程 |
| `closedUnitRejectsConcurrentCalls` | 两线程均 19（site=−1） | 卸载终态一致 |

门槛：全量零失败；本套 6/6；输出无 warning（除既有 374 条债务）。
