# 设计：审计表随发射器实例

## 1. 现状

```
A64Emitter.auditTls : ThreadLocal<ArrayList<Int64>>   // 静态
noteMemBase(reg)  -> auditList().add(reg)            // 每次内存操作一次 TLS get
resetAuditMemBases() / auditMemBasesSnapshot()       // 静态
```

`A64Compiler.compileOnce` 每次 `new A64Emitter(farCond)`，prologue 发射完后
`resetAuditMemBases()`（丢弃 prologue 的记录），`lower(unit)`，再 `auditMemBasesSnapshot()` 校验。

## 2. 方案

```cangjie
internal class A64Emitter {
    private let audit: ArrayList<Int64> = ArrayList<Int64>()

    func noteMemBase(reg: Int64): Unit { this.audit.add(reg) }
    func resetAudit(): Unit { this.audit.clear() }
    func auditSnapshot(): Array<Int64> { this.audit.toArray() }
}

// A64Compiler.compileOnce
e.resetAudit()
lower.lower(unit)
if (!A64Emitter.auditAllows(e.auditSnapshot())) { return None }
```

`auditAllows` 仍是静态纯函数（只读数组），`EmitAudit_test` 的谓词用例不受影响。

## 3. 等价性

| 维度 | 旧（ThreadLocal） | 新（实例字段） |
| --- | --- | --- |
| 并发隔离 | 线程私有 | 每 `compileOnce` 一个新 `A64Emitter`，互不可见 |
| 记录内容 | 每条 `strOff`/`ldrOff` 的 `rn` | 同 |
| reset 时点 | prologue 之后 | 同（`e.resetAudit()` 位置不变） |
| 允许集 | `{19,20,29,31}` | 同 |

嵌套/重入：`A64Emitter` 不跨函数复用（`compileOnce` 内新建），不存在旧实例残留。

## 4. 护栏

| 用例 | 作用 | 改前 | 改后 |
| --- | --- | --- | --- |
| `CompileConcurrency_test` | 4 线程 × 10 次并发编译，结果必须正确 | 绿 | 绿（同一份语义护栏，跨实现有效） |
| `EmitAudit_test`（A64 两条） | 绝对地址豁免、采集/重置语义 | 改为实例 API 后仍绿 | 绿 |
| `A64AuditIsolation_test` | 两个发射器互不串味 | 改为实例 API 后仍绿 | 绿 |

后两者在本变更中**必须改 API**（静态方法消失），因此它们的「改前绿」以旧 API 版本为准，
「改后绿」以新 API 版本为准；语义断言逐条保留。

## 5. 判定

MOV = `max(3%, 2×离散度)`；预期 `codegen` −8%，与实测 598 次 × 300 ns 同量级。
