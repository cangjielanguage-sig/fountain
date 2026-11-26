# Tasks

- [x] T1 主规格「统一调用包装」改为 `close` 口径（入口 = 单元卸载、包装 = 释放闭包、`close()` = `close(0)`、`isClosed()` 为方法）
- [x] T2 场景改名：`close 协议`、`callForFn 并发`、`卸载逐出缓存`
- [x] T3 当前设计文档同步：`design-m2.md` API 表、`design-parallel-call.md` 的释放入口措辞
- [x] T4 `grep unloadFn` 清零（主规格、当前设计文档、README）；历史归档保留
- [x] T5 `openspec validate --all` 9/9 通过；归档
