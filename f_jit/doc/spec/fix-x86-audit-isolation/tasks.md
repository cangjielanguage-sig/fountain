# 任务：fix-x86-audit-isolation

- [x] L1.1 新增 `X86AuditIsolation_test`：另一线程写入后本线程快照必须为空。
- [x] L1.2 在**未改动**实现上跑：必须 **FAILED**（证明缺陷存在）。
- [x] L2.1 `BackendX86_64` 审计表改 `ThreadLocal`；四个静态方法走线程私有列表。
- [x] L3.1 护栏转绿；`EmitAudit_test` / `X86Compile_test` / `X86Lower_test` / `CompileConcurrency_test` 全绿。
- [x] L3.2 全量零失败。
- [x] L4.1 `verify.md`（记录「改前红、改后绿」）；L4.2 镜像 + 校验；L4.3 归档 + §14。
