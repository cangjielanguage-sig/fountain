# 任务：clarify-last-escaped-scope

- [x] T1.1 `lastEscaped` 的写移入 `synchronized(this.mtx)`。
- [x] T1.2 `lastEscapedClosure()` / `lastPromotionGroup()` 的读加锁。
- [x] T1.3 两个访问器的文档注释写明「单线程诊断口径；并发请用 `callForFn`」。
- [x] T1.4 新增 `LastEscapedScope_test`：2 线程制造 `lastEscaped` 争用 + 2 线程 `callForFn`，结果全对、句柄回基线。
- [x] T2.1 `JitFunctionClosure_test` / `CallForFnConcurrency_test` / 新用例全绿。
- [x] T2.2 全量零失败。
- [x] T3.1 `verify.md`；T3.2 镜像；T3.3 归档 + 提交。
