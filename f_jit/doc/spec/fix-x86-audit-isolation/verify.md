# 验证：fix-x86-audit-isolation

## 1. 缺陷证据（改前必须红）

新增 `src/backend/X86AuditIsolation_test.cj`：

- `auditListIsThreadLocal`：另一线程 `noteMemBase(15)` 之后，本线程快照必须为空。
- `allowsSetUnchanged`：`-1` 哨兵与 `{4,5,15}` 允许集不变（回归面）。

在**未改动**实现上运行：

```
[ PASSED ] CASE: allowsSetUnchanged
[ FAILED ] CASE: auditListIsThreadLocal
Summary: FAILED: 1
```

失败原因正是缺陷本身：进程级静态 `ArrayList` 让别的线程的写入出现在本线程快照里。
（同样的机制下，`resetAuditMemBases()` 也能清空别人的记录 ⇒ `auditAllows([])` 返回 true
⇒ 非法基址被静默放行。）

## 2. 修复

`BackendX86_64.auditMemBases: ArrayList<Int64>` → `ThreadLocal<ArrayList<Int64>>`；
`noteMemBase` / `noteAbsMem` / `resetAuditMemBases` / `auditMemBasesSnapshot` 走线程私有列表；
`auditAllows` 保持静态纯函数（不变）。

选 ThreadLocal 而不是实例字段：x86 的发射助手是 `BackendX86_64` 上的静态函数，
10 处调用分散在 `X86Lower` 里，且 `EmitAudit_test` 直接依赖静态采集/重置 API；
ThreadLocal 是此处最小且完整的修法。

## 3. 改后

| 用例 | 条数 | 结果 |
| --- | --- | --- |
| `X86AuditIsolation_test` | 2 | 全绿（改前 1 红） |
| `EmitAudit_test` | 6 | 全绿（静态 API 未变，用例无需改动） |
| `X86Compile_test` | 11 | 全绿 |
| `X86Lower_test` | 50 | 全绿 |
| `CompileConcurrency_test` | 1 | 全绿 |

## 4. 全量

`cjpm test --parallel 1`：**1248 / 1248，0 失败 0 错误**（较改前 1246 多出本次新增的 2 条护栏）。

## 5. 说明

本变更是**正确性修复**，不附带性能主张：它给 x86 的每次内存操作加了一次 TLS `get`，
与 aarch64 侧长期使用的设计一致；aarch64 上的实测（`optimize-emit-audit`）显示该成本
低于本机测量分辨率。
