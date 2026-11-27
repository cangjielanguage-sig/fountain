# 任务：optimize-emit-audit

## I1 基线

- [x] I1.1 计数：598 次 `noteMemBase`/编译（250 条字节码指令、2358 机器字）。
- [x] I1.2 早前估算 `ThreadLocal.get ≈ 300 ns` ⇒ 约 180 µs（**本轮实测未兑现**，见 verify §2）。
- [x] I1.3 改动前 `CompileConcurrency_test` 绿。

## I2 实现

- [x] I2.1 `A64Emitter` 加 `audit` 实例字段；`noteMemBase/resetAudit/auditSnapshot` 改实例方法。
- [x] I2.2 `A64Compiler.compileOnce` 改用实例 API；`auditAllows` 保持静态。
- [x] I2.3 删除 `auditTls` 与 `auditList()`。

## I3 测试改造

- [x] I3.1 `EmitAudit_test` 的 A64 两条改实例 API，断言不变。
- [x] I3.2 `A64AuditIsolation_test` 改两实例隔离，断言不变。

## I4 验证

- [x] I4.1 `CompileConcurrency_test` / `EmitAudit_test` / `A64AuditIsolation_test` / `A64Emitter_test` / `Golden_test` 全绿。
- [x] I4.2 A/B：`codegen` 中位数两臂 —— **无显著差异**（快 +1.7%、慢 −4.4%）。
- [x] I4.3 全量 1246/1246。

## I5 收口

- [x] I5.1 `verify.md`（如实记录「未测得收益」）；I5.2 镜像 + 校验；I5.3 归档 + §12；I5.4 删探针。
