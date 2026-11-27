# 任务：optimize-jitcontext-pool（实验后 **revert**）

- [x] T1.1 `NativeMem` 新增真实分配计数（实验用，已随回退移除）。
- [x] T1.2 `JitContext` 池化：先 `ThreadLocal` 版，再 `RuntimeState` 版。
- [x] T1.3 复用后全量重写 8 个字、`HostFault.clearWith` 顺序不变（两版都做了）。
- [x] T2.1 `JitContextPool_test` 4 条：池复用 / 错误槽不残留 / 宿主异常不串 / 嵌套取不同块——全绿。
- [x] T2.2 变异验证：取消池复用 ⇒ `poolReusesBlocks` FAILED（其余 3 条 PASSED）。
- [x] T2.3 基准复测：C1 405→855（TLS 版）/376、348（rs 版）；L1 2952→3407/3128/3248。
- [x] T2.4 **判定：不 adopt**——C1 的 −14% 无法传导到 L1，两个池化版本 L1 均变慢。
- [x] T2.5 代码全部回退（4 个文件 `git checkout`，测试文件删除），工作区干净。
- [x] T3.1 `verify.md`（三组数据 + 结论 + 教训）；T3.2 镜像；T3.3 归档 + 提交（仅文档）。
