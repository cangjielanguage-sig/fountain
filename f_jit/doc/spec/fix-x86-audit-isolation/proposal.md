# x86 发射审计表的并发隔离（正确性修复）

## Why

`BackendX86_64.auditMemBases` 是**进程级静态 `ArrayList<Int64>`**，`noteMemBase` /
`noteAbsMem` 直接 `add`、`resetAuditMemBases` 直接 `clear`，全程无锁。

这带来两个问题：

1. **数据竞争**：`X86Compiler.compileFunctionWith` 每函数 `new X86Lower`，两个线程并发编译时
   双方的 `add` 落在同一张表上（`ArrayList` 非线程安全，可能越界或丢项）；
2. **审计被静默绕过**：A 线程的 `resetAuditMemBases()`（在 `lower()` 开头）会清掉 B 线程
   已记录的项，B 的 `auditMemBasesSnapshot()` 可能为空 ⇒ `auditAllows([])` 返回 true ⇒
   **本该拒绝的非法内存基址被放行**，G5 这条安全网在 x86 并发下失效。

A64 侧在 `optimize-compile-path` 的 C0 里已经修过同一个缺陷（改 `ThreadLocal`），
x86 侧当时漏了；`CompileConcurrency_test` 在 aarch64 上只走 A64 路径，因此从未暴露。

## What Changes

`BackendX86_64` 的审计表改 `ThreadLocal<ArrayList<Int64>>`，`noteMemBase` / `noteAbsMem` /
`resetAuditMemBases` / `auditMemBasesSnapshot` 走线程私有列表；`auditAllows` 保持静态纯函数。

**为什么不用实例字段**（A64 后来改成了实例）：x86 的发射助手是 `BackendX86_64` 上的
**静态函数**，10 处调用分散在 `X86Lower` 的方法里；改成实例要动这些助手或给 `X86Lower`
传审计对象，而 `EmitAudit_test` 又直接依赖静态采集/重置 API。ThreadLocal 是此处
最小且完整的修法。

## Impact

- 修复 x86 并发编译的审计竞态与「审计被清空」缺陷；
- 影响文件：`src/backend/BackendSelector.cj`（+ 护栏 `src/backend/X86AuditIsolation_test.cj`）；
- 性能：与 A64 侧同一设计（每内存操作一次 TLS get），A64 上实测**无显著成本**；
- 风险：低。护栏在旧实现上必须**红**（这正是缺陷本身），修后必须**绿**。
