# 任务：add-concurrency-matrix-tests

- [x] T1.1 基线：现有并发用例全绿（`CompileConcurrency_test` 1/1）。
- [x] T1.2 新增 `src/ConcurrencyMatrix_test.cj`：5 个用例（4 类场景 + 编译/调用混合）。
- [x] T1.3 单类运行全绿（5/5，合计约 70 ms）。
- [x] T2.1 变异 M1：`CompileCache.claim` 去掉去重判定 ⇒ 用例 1 FAILED（runs=6）。
- [x] T2.2 变异 M2：`UserHelperTable` 的栈改为进程级共享（无锁）⇒ 用例 4 ERROR（越界）。
- [x] T2.3 变异 M2b：共享表 + 加锁 + `pop` 不弹 ⇒ 用例 4 FAILED（bad=594，静默错值）。
- [x] T2.4 恢复实现：单类 5/5、全量 1253/1253 全绿。
- [x] T3.1 `verify.md`：记录基线、变异证据、恢复后结果与边界。
- [x] T3.2 `doc/spec/<change>/` 镜像 + 字节校验。
- [x] T3.3 `openspec archive` + 提交推送。
