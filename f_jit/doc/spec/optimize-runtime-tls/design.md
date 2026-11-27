# 设计：线程私有运行期状态合并

> 变更 `optimize-runtime-tls`（`skip_specs: true`，纯内部布局重构）。
> 权威数据见 `proposal.md` 与 `doc/optimize-call-path.md` §16（实施后补）。

## D1 为什么合并成单个 holder，而不是只削减访问次数

两条路都可行，但收益差一倍：

| 方案 | 剩余 TLS 次数 | 预期收益 | 改动面 | 判定 |
| --- | --- | --- | --- | --- |
| A. 只削减：窗口返回 base/cap、无 deadline 不写、flags 门控 iter/fault | 14 → 6 | ~−2.5 µs（29%） | 局部，不改存储 | 备选 |
| **B. 合并 holder + 同 A 的削减** | **14 → 2** | **~−3.8 µs（44%）** | 5 个模块的存储搬家 | **采纳** |

关键理由：`ThreadLocal` 的成本是**每次访问**约 300 ns，不是"每个变量"约 300 ns。
A 方案仍要付 6 次；B 把 5 份存储放到同一个对象里，之后全是字段读写（纳秒级）。
且 B 是**一次性结构收益**：以后新增线程级状态（GC 暂存、trace 开关等）零 TLS 成本。

## D2 `RuntimeState` 的字段与归属

```cangjie
protected class RuntimeState {
    public var deadlineNanos: Int64 = -1      // 原 RuntimeEnv.tls
    public var fnTableBase: Int64 = 0         // 原 MachineEnv.tls
    internal let wins: ArrayList<Win> = ArrayList<Win>()   // 原 HandleTable.winTls
    internal let iters: IterState = IterState()            // 原 IterTable.tls
    internal var faults: ?HashMap<UInt64, FaultEntry> = None // 原 HostFault.tls（懒建）
}
```

- `RuntimeEnv` 新增 `private static let stateTls = ThreadLocal<RuntimeState>()` 与
  `internal static func current(): RuntimeState`（首次 `get` 为空时构造并 `set`）。
- `deadlineNanos` / `setDeadline` / `clearDeadline` 的公开 API 保留，内部改读 `current().deadlineNanos`
  （测试与桥仍可直接用；调用热路径改用 `current()` 一次拿到对象后直接写字段）。
- `MachineEnv` 的公开属性 `fnTableBase` 保留，内部改读 `current().fnTableBase`；
  `JitExecutor` 跨包读该属性即可（`RuntimeState` 为 module 级可见）。
- `Win` / `IterState` / `FaultEntry` 从 `private` 放宽到 `internal`（同一 `fountain::f_jit.runtime` 包），
  仅用于 `RuntimeState` 的字段类型；用户面不可见。

**初始化顺序**：`RuntimeState` 构造时只建 3 个空容器（两个 `ArrayList` + 一个 `IterState`），
不建 `faults` 表（保持旧实现的"无异常零分配"）。首次 `HostFault.record` 时才建表。

## D3 `IterTable` / `HostFault` 用 `ctx.flags` 门控

旧实现每次调用都在 `finally` 里做一次 TLS get，即使本次调用从未用过迭代器、从未抛异常。
改为在 `JitContext.flags` 上开两位：

| 位 | 名称 | 何时置位 | 何时消费 |
| --- | --- | --- | --- |
| bit4 | `ITER` | `IterTable` 首次创建条目时（helper 内） | `JitFunction.call` 的 finally：仅置位时 `clearAll(rs)` |
| bit5 | `FAULT` | `HostFault.record` 时 | `JitContext.free` / 桥收尾：仅置位时清表 |

- 置位是**非托管内存的一次读改写**（`ctx.flags` 在 ctx 内，无 TLS、无锁）；
- 健康路径（绝大多数）两位均为 0 ⇒ **0 次 TLS**；
- `clearAll(rs)` / `clear(ctx)` 仍保留无 rs 的重载，内部走 `current()`，供测试与旧调用点使用。

## D4 `JitExecutor.invokeOff` 的条件 set

旧实现每次调用固定 3 次 TLS：`get saved` + `set(table)` + `finally set(saved)`。
改为：

```cangjie
let cur = MachineEnv.fnTableBase
let needRestore = cur != this.table.base()
if (needRestore) { MachineEnv.setFnTableBase(this.table.base()) }
try { ... } finally { if (needRestore) { MachineEnv.setFnTableBase(cur) } }
```

- 稳态（同一单元连续调用、无重入）`cur == base` ⇒ **1 次 get、0 次 set**；
- 重入（JIT 内调宿主闭包再回调 JIT）`cur != base` ⇒ 仍然 set/restore，语义不变。

## D5 deadline 的条件写

旧实现无论 `options.deadline` 是否为 `None`，都执行 `setDeadline(...)` 与 `setDeadline(saved)`。
改为：

```cangjie
let rs = RuntimeEnv.current()
let saved = rs.deadlineNanos
let want = RuntimeEnv.deadlineNanosOf(options.deadline)
if (want != saved) { rs.deadlineNanos = want }
try { ... } finally { if (want != saved) { rs.deadlineNanos = saved } }
```

- 无期限的常规调用（`saved == want == -1`）⇒ **0 次写**；
- 嵌套调用仍按栈式恢复（`saved` 是本层的旧值）。

## D6 重入与并发等价性

- **线程私有**：`RuntimeState` 只存在于当前线程的 TLS 中，跨线程不可见 ⇒ 与旧 5 份 TLS 的隔离性相同；
- **重入**：同一线程的重入共享同一个 `RuntimeState`，但 deadline / fnTable 都按"读旧值 → 写新值 → finally 恢复旧值"
  的栈式协议操作，嵌套层各自恢复自己的旧值，与旧实现逐位一致；
- **窗口栈**：`Win` 栈本来就在 TLS 里，合并后仍是同一线程的同一个 `ArrayList`，`open/reset` 的配对不变；
- **异常旁路**：`FaultEntry` 按 ctx 地址索引，同一线程内多个嵌套调用各用各的 key；合并后 key 空间仍是线程私有；
- **可见性**：`RuntimeState` 为 module 级（`protected` 收口），不进入用户 API。

## D7 护栏与变异

必须保持绿的既有用例：

| 用例 | 保护的性质 |
| --- | --- |
| `ThreadLocalEnv_test` | deadline / fnTableBase 的线程私有性 |
| `WindowIsolation_test` | 窗口栈的线程隔离与开合配对 |
| `HostFaultTls_test` | 异常 cause 不跨线程串味 |
| `IterLifecycle_test` | 迭代器表的调用级清理 |
| `UnloadConcurrency_test` / `ParallelCall_test` | 并发调用/卸载 |

新增护栏（本变更）：

1. `RuntimeStateIsolation_test`：4 线程各自设置 `deadlineNanos`，互不观察到对方的值；
2. `RuntimeStateReentry_test`：JIT 内调宿主闭包再回调 JIT，内层 deadline/fnTable 恢复后外层值不变；
3. `RuntimeStateFlags_test`：健康调用不置 `ITER/FAULT` 位；用过迭代器/抛过异常后位置位并在收尾清除。

变异验证：

- 把 `RuntimeEnv.current()` 改成"每次返回新对象"⇒ 隔离/重入用例必须变红；
- 把 `RuntimeState` 改成进程级单例 ⇒ 隔离用例必须变红；
- 去掉 `ITER` 门控（恒清）⇒ 迭代器生命周期用例必须仍绿（证明门控只是加速，不是语义）；
  反之，把门控写成"恒不清"⇒ `IterLifecycle_test` 必须变红。
