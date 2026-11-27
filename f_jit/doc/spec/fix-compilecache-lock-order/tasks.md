# 任务：fix-compilecache-lock-order

- [x] T1.1 `CompileCache.finish`：`bindCacheKey` 移到全局锁之外（先 bind、后进锁发布）。
- [x] T1.2 代码注释写明「bind 时对象不可见，故不存在并发 close」这一前提。
- [x] T1.3 `CompileCache_test` 4 条 + `ConcurrencyMatrix_test` 5 条全绿。
- [x] T2.1 全量零失败。
- [x] T3.1 `verify.md`（说明锁序收敛与不变式）；T3.2 镜像；T3.3 归档 + 提交。
