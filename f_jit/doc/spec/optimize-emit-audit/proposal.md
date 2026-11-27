# A64 发射审计表：ThreadLocal → 发射器实例字段

## Why

`A64Emitter.strOff` / `ldrOff` 每次内存操作都调 `noteMemBase`，后者走
`auditList()` → `auditTls.get()`。实测每次编译 **598 次**（250 条字节码指令、2358 条机器字），
按本项目早前测得的 `ThreadLocal.get ≈ 300 ns` 计，约 **180 µs**，占 `codegen`（2.05–2.39 ms）的 **8%**。

这个 ThreadLocal 是 `optimize-compile-path` C0 的产物：当年审计表是进程级 `ArrayList`，
并发编译会互相踩，改成线程私有后成本就落在了每次内存操作上。
但审计的生命周期**恰好等于一次 `A64Compiler.compileOnce`**（一次编译一个 `A64Emitter`），
所以根本不需要线程级隔离——**实例字段**既天然隔离、又没有 TLS 开销。

## What Changes

1. `A64Emitter` 新增 `private let audit: ArrayList<Int64>`；`noteMemBase` / `resetAudit` /
   `auditSnapshot` 从静态方法改为**实例方法**。
2. `A64Compiler.compileOnce` 改用 `e.resetAudit()` / `e.auditSnapshot()`；
   `A64Emitter.auditAllows(...)` 保持静态纯函数。
3. `ThreadLocal` 字段与 `auditList()` 删除。

**语义不变**：审计集合的内容、`reset` 的时点（prologue 之后、`lower` 之前）、
允许集 `{19,20,29,31}` 与拒绝行为逐条不变；隔离性由「每编译一个新实例」保证。

## Impact

- 收益目标：`codegen` **−180 µs（约 −8%）**；单次编译约 −3~4%；
- 影响文件：`src/backend/A64Emitter.cj`、`src/backend/A64Compiler.cj`、
  `src/backend/EmitAudit_test.cj`、`src/backend/A64AuditIsolation_test.cj`；
- 风险：`EmitAudit_test` / `A64AuditIsolation_test` 直接调静态 API，需同步改为实例 API；
  隔离语义用「4 线程并发编译」的 `CompileConcurrency_test` 兜底（改前改后都必须绿）。
- **x86 不在本变更内**：`BackendX86_64.auditMemBases` 是进程级静态表（无 TLS 开销但有并发缺陷），
  按用户要求放到最后单独修。
