# 任务

> 方案与门槛见 `f_jit/doc/optimize-compile-path.md`；本变更 `skip_specs: true`（纯内部优化）。

- [x] M0.1 临时给 `CodeBuffer.alloc` / `seal` 加计数与纳秒累加（用后删除）。
- [x] M0.2 探针：1 线程 / 4 线程各编译 12 段不同源码，记录 mmap/mprotect 次数、耗时、占比。
- [x] M0.3 判定：占比 ≥15%（或 4 线程 ≥25%）⇒ 立 C3；否则记录「C3 不做」。
- [x] M0.4 删除测量代码，确认工作区无残留。

- [x] C1.1 护栏用例：同 key 4 线程并发编译 → `CompileCache.runs()` 恰为 1、四个结果同一实例、无异常。
- [x] C1.2 实现 `awaitReady` 指数退避 + 墙钟预算。
- [x] C1.3 微基准：一个线程占住 key K 不 finish，另起 4 个等待者；测另一线程对 key X 的
  `claim+finish` 延迟（改动前 vs 改动后），目标下降 ≥30%。
- [x] C1.4 全量回归；单独提交。

- [ ] C2.1 行为用例：注册函数后编译可见；再注册另一个后再次编译可见（缓存失效正确）。
- [ ] C2.2 实现 `snapCache` + 各注册入口失效。
- [ ] C2.3 微基准：共享 `Compiler` 的 4 线程编译扩展比，目标提升 ≥10% 或 snapshot 占比 <3%。
- [ ] C2.4 全量回归；单独提交。

- [x] C3 **取消**：M0 实测 mmap+mprotect 占 2.4%/5.9%，未达 15% 门槛（文档 §6）。

- [ ] X.1 写 `verify.md`；`doc/optimize-compile-path.md` 填决策日志；镜像
  `f_jit/doc/spec/optimize-compile-path/`；`openspec validate --strict`；归档。

## 不做

- 不改前端、产物格式、公开 API；
- 不引入条件变量（标准库仅 `Monitor` 且已废弃），C1 用指数退避。
