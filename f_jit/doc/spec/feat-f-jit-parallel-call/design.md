# Design

## Context

`HandleTable` 是全静态的单表：8 个并行 `ArrayList` + `freeSlots` + `windowBase/Top/Used/windowStack` + 单 `Mutex`（`HandleTable.cj:88-141`）。`openWindow` 用 `windowBase = objs.size`（全表尾），`resetWindow` 按窗口清单清账。ID 布局 `idx:u32|tag:u16|gen:u16`，`idx` 就是表下标。提升（`moveOutGroup`）承诺 **ID/gen 不变**。

这一条契约决定了方案：**不能按线程分表**——分表意味着提升时要改 ID，或让包装的 `closureId` 只在创建线程可解析。

## 决策

### D1 单表 + 每调用窗口切片（不做线程分表）

- 全局 ID 空间不变 ⇒ 常量、提升槽、`closureId` 天然跨线程可解析，`callForFn` 包装可跨线程。
- 窗口从「全表一个」变为「每次调用一段**互不重叠**的切片」；`ctx.hwBase/hwTop` 成为分配依据（现在只是镜像，`HandleTable.cj:262/269`）。
- 重入（宿主闭包回调再进 JIT）在**同一线程**上再开一段切片；窗口栈改为线程私有。

### D2 切片分配

- 分配器：`AtomicInt64` 的 bump 指针 + 短锁保护的 `freeSlots` 回收；一次调用只分配一次（不是每个 helper 一次）。
- 切片大小 = `max(initialCapacity, 需求)`；切片内用自有 free list，`resetWindow` 只释放**本切片**的槽。
- 触顶（全局 `capacityLimit`）仍以 16 失败。

### D3 槽存储的并发安全

- 槽写入天然按切片隔离：一个槽在同一时刻只属于一个窗口 ⇒ **槽内读写不需要锁**。
- 需要额外保护的只有：目录/容量增长、槽位分配与回收、`gen` 的失效判定。
- 选型在 P0 spike 中定：① 分块存储（目录定长 + 块惰性分配，块内定长数组不移动）；② 预分配 `capacityLimit` 的定长数组（内存换简单）。**限制：任何活跃窗口存在时不得发生底层数组搬迁**，否则并发写会丢。

### D4 线程私有环境

`RuntimeEnv.deadlineNanos`、`MachineEnv.fnTableBase`（H57 用）、`UserHelperTable.stack` 改 `ThreadLocal`；`envMtx` 删除。重入时保存/恢复。

### D5 每次调用私有

`lastEscaped` 是**单元级字段**（`JitFunction.cj:95`），并发下会被别的线程覆盖 ⇒ 改为调用返回值/线程局部，`callForFn` 取本次调用自己的提升组。

### D6 生命周期

`state`/`active` 改原子；`unload` 不再依赖 `callMtx`，靠 `active` 排空：`state=1` 拒新调用（19）、等 `active==0`、超时回退。`unloadFn` 对提升组的释放需原子（同组多线程调用）。

### D7 与缓存/常量的关系

编译产物、常量 pin、`CompileCache` 语义不变；常量在编译期 pin 进全局表，跨线程直接可用（不需要每线程重 pin——这是选单表的主要收益）。

### D8 调用路径上的其余全局点（必须一并处理）

只删 `callMtx` 不够，以下三处会在并行后变成新的串行点：

- **`IterTable`**：全局表 + 全局锁，且 `open/next/key/value/close` **每一次**都加锁（`IterTable.cj:52-112`）。
  它本来就是**调用级**资源（调用结束 `clearAll`），游标含 `gen` 不跨调用 ⇒ 改为每调用/每线程私有表，
  锁随表消失。一个 `for (k in map)` 循环有 N 次 `next`，不改就是最热的争用点。
- **`JitContext.mallocCount/freeCount`**：`public static var`，每次 create/free 自增（`JitContext.cj:26-27`）
  ⇒ 数据竞争 + 缓存行争用；改 `AtomicInt64` 或每线程计数汇总。
- **切片分配器**：`AtomicInt64` bump + 短锁回收，**每次调用一次**（不是每次 helper），不构成执行串行；
  极限场景可加「每线程 free 缓存」，列为 P6 可选优化。

其余点不阻塞：`CompileCache` 只在编译路径（按 key 认领）；`AdapterRegistry` 在 pin 时查一次；
`PromotionGroup` 是 per-group；诊断（`DbgDump`/Tracer）只在失败或开启时。

## 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 底层数组在活跃窗口期间搬迁 | 并发写丢失/读到旧数组 | P0 定存储选型；分配器保证「有活跃窗口时不搬迁」，或在切片分配前预扩容 |
| 槽位回收与在飞句柄竞态 | 读到别人的对象（类型混淆） | 槽只属于一个切片；`gen` 校验保留；回收只由本切片 owner 发起 |
| 提升/释放跨线程 | 计数错乱、早释放 | `PromotionGroup` 加锁（现有 `releaseAll` 需改为原子引用计数） |
| 单线程回归 | 结果/错误码变化 | 全量对拍；单线程路径保持同一分配顺序 |
| 性能不达预期 | 并发退化 | P6 基准：2/4/8 线程扩展比，低于目标则回看分配器与 false sharing |
