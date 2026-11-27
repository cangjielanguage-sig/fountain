# 宿主签名两表：不可变快照 + 结构键索引

## Why

`CallMarshal.marshalHostClosure` → `HandleTable.pinHostClosure` 的窗口去重只在**同一窗口**内有效；
跨调用时要新建 `HostCallback(fn, sig)`，而它的构造函数会进两张全局表：

```cj
this.adapter = SignatureRegistry.adapterOf(sig.params, sig.paramNames, sig.ret, sig.retName)
this.plan = SignatureTable.getOrBuild(sig)
```

两表都是「`ArrayList` + 一把 `Mutex` + **线性扫描 `sameShape`**」。实测（临时探针，已删）：

| 指标 | 值 |
| --- | --- |
| `HostCallback(fn, sig)` 构造（1 线程） | **615 ns/次** |
| 同（4 线程，每 op） | **1174 ns** |
| 扩展比 | **0.52×（越并越慢）** |

与 Phase 2 之前的句柄锁、P4-A 之前的 `JitBindSupport` 是同一型 convoy：读多写少却全程持锁线性扫。
影响面：**实参声明为宿主闭包（13 型）的 JIT 调用**，每次调用付一次（普通对象实参不走这条路）。

## What Changes

两张表都改成「**结构键 `HashMap` + 不可变快照 + `AtomicReference` 发布**」：

| 表 | 现状 | 改后 |
| --- | --- | --- |
| `SignatureRegistry`（base） | 全局锁 + 线性扫 `sameShape`；id = 数组下标 | 快照含 `Array<HostSignature>`（**保留线性扫，不做键索引**）；`register` 写时复制发布，`find`/`adapterOf`/`get` 零锁 |
| `SignatureTable`（runtime） | 全局锁 + 线性扫；`builds` 普通计数 | 快照含 `Array<SignaturePlan>` + `builds`；`getOrBuild` 读快照命中即返回，未命中在写锁内双检后新建并发布 |

> **实施中发现**：原计划的「字符串结构键 `HashMap`」被实测否决 —— 表规模只有个位数条目时，
> 拼键（`StringBuilder` + 插值）比线性扫更贵（`adapterOf` 349 → **790 ns**）。
> 改为「只去锁、保留线性扫」后 `adapterOf` 降到 233 ns。详见 design D1。

**语义保持不变**（这是等价优化）：

- id 仍按**首次登记顺序**从 0 递增、稳定；
- 同结构重复 `register` 仍返回既有 id（幂等）；
- `MAX_ENTRIES = 128` 仍生效：超限后**不再缓存**但照常返回新计划（`builds` 仍 +1）；
- `SignatureTable.enabled` 开关语义不变；
- `resetForTest` 仍清空。

不新增/修改规格 requirement（`skip_specs: true`），只改实现与索引结构。

## Impact

- 收益目标：`HostCallback` 构造从 615 ns 降到 **≤200 ns**，4 线程扩展比 ≥1.5×；
- 影响文件：`src/base/HostSignature.cj`、`src/runtime/SignaturePlan.cj`（+ 新增并发护栏用例）；
- 风险：键构造必须与 `sameShape` **逐位等价**（漏掉任一维度会让不同签名撞 id）——
  以「逐位码 + 逐位类名 + 返回码 + 返回名」拼键，并用「同类不同类名的两个签名不撞」用例锁住。
