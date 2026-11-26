# 并行调用设计（feat-f-jit-parallel-call）

> 状态：**已设计、未实施**（OpenSpec 变更 `feat-f-jit-parallel-call`，`validate --strict` 通过）。
> 目标：编译一次 → 所有线程共享同一产物 → 并行执行、互不干扰 → 每线程独立调用上下文；
> 且 `callForFn` 返回的闭包包装**可跨线程**调用与释放。

## 1. 现状：串行的真正原因

表面看是两把锁，根因是**一张全局句柄表只有一个全局窗口**。

| 事实 | 位置 |
| --- | --- |
| `JitFunction.call` 全程在**进程级** `callMtx` 内 | `JitFunction.cj:49/150` |
| `JitExecutor.invoke` 另有 `envMtx`（因函数表基址是全局变量） | `backend/JitExecutor.cj:37/126/150` |
| 句柄表全静态：8 个并行数组 + `freeSlots` + `windowBase/Top/Used/windowStack` + 单 `Mutex` | `runtime/HandleTable.cj:88-141` |
| `openWindow` 直接拿**全表尾**当窗口基址 | `windowBase = objs.size` |
| `ctx.hwBase/hwTop` 只是全局窗口的**镜像**，不是分配依据 | `HandleTable.cj:262/269` |
| `lastEscaped` 是**单元级字段**，`callForFn` 靠它取提升组 | `JitFunction.cj:95` |
| `deadline` 是全局静态变量，且**写在调用锁之外** | `RuntimeEnv.cj:30`、`JitFunction.cj:146-160` |

两个调用同时 `openWindow` 会互相清窗——`callMtx` 是在替这张表兜底。所以「删锁」不可行。

## 2. 目标与非目标

**目标**

- 同一 `JitFunction` 被 N 个线程并发 `call`，真正并行；结果/错误码/site 与串行逐位一致。
- 每次调用独占窗口切片与 `JitContext`；线程私有 `deadline`、函数表基址、user-helper 栈。
- 跨线程包装：A 线程 `callForFn` → B/C 线程调用 → D 线程 `unloadFn`。
- `unload` 语义不变：等所有线程在飞调用排空，期间新调用 → 19。

**非目标**

- 编译管线并行化（已按指纹并行）。
- 跨进程共享产物。

## 3. 关键决策

### D1 保持单表，不做线程分表

提升（`moveOutGroup`）的契约是 **ID/gen 不变**；跨线程包装的 `closureId` 必须全局可解析。
分表意味着提升时要改 ID（深改所有引用）或让包装只在创建线程可用——两者都不可接受。

⇒ 全局句柄空间不变；常量、提升槽、`closureId` 天然跨线程有效。

### D2 每调用独占窗口切片

- 窗口从「全表一个」变为「每次调用一段互不重叠的切片」。
- `ctx.hwBase/hwCap/hwTop` 从镜像变成真实分配依据。
- 重入（宿主闭包回调再进 JIT）在同一线程再开一段，窗口栈改**线程私有**。
- `resetWindow` 只释放**本切片**的槽。

### D3 槽存储的并发安全

- 槽在同一时刻只属于一个窗口 ⇒ **槽内读写无需加锁**。
- 需保护的只有：切片分配、槽回收、目录/容量增长、`gen` 失效判定。
- 存储选型待 P0 spike 定：① 分块存储（定长目录 + 块惰性分配，块不移动）；② 预分配 `capacityLimit` 定长数组。
- **硬约束：任何活跃窗口存在时，底层数组不得搬迁**，否则并发写会丢。

### D4 线程私有环境

| 状态 | 现状 | 改后 |
| --- | --- | --- |
| `deadlineNanos` | `static var` | `ThreadLocal`（重入保存/恢复） |
| `MachineEnv.fnTableBase` | 全局 + `envMtx` | `ThreadLocal`，删 `envMtx` |
| `UserHelperTable.stack` | 静态栈 + 锁 | `ThreadLocal` |

### D5 每次调用私有

- `lastEscaped` → 改为 `callForFn` 的本次调用返回值，不再是单元级字段。
- `JitContext`、解释器 locals/stack、A64 帧：本来就是每次调用私有，无需改。

### D6 生命周期

- `state`/`active` 改原子；`unload` 不再借 `callMtx`，靠 `active` 排空：
  `state=1` 拒新调用（19）→ 等 `active==0` → 终态；超时回退可用。
- `unloadFn` 对提升组的释放需原子（同一包装可能被多线程同时释放）。

### D7 缓存与常量

编译产物、常量 pin、`CompileCache` 语义不变。常量在编译期 pin 进全局表，跨线程直接可用
（不需要每线程重 pin——这是选单表的主要收益）。

### D8 调用路径上其余必须一并处理的全局点

| 点 | 问题 | 处理 |
| --- | --- | --- |
| **`IterTable`** | 全局表 + 全局锁，`open/next/key/value/close` **每次都加锁**（`IterTable.cj:52-112`）；`for (k in map)` 有 N 次 `next` | 改**调用私有**表（本就是调用级资源，游标含 `gen` 不跨调用），锁随表消失 |
| `JitContext.mallocCount/freeCount` | `public static var`，每次 create/free 自增（`JitContext.cj:26-27`）⇒ 数据竞争 + 伪共享 | 改 `AtomicInt64` 或每线程计数 |
| 切片分配器 | 每次调用一次原子/短锁 | 不构成执行串行；P6 可选每线程 free 缓存 |

不阻塞的点：`CompileCache` 只在编译路径；`AdapterRegistry` 在 pin 时查一次；`PromotionGroup` 是 per-group；
`DbgDump`/Tracer 只在失败或开启时。

## 4. 改动清单（预估）

| 文件 | 改动 |
| --- | --- |
| `runtime/HandleTable.cj` | 窗口切片化 + 分配器 + 存储并发安全（最大一块） |
| `runtime/IterTable.cj` | 全局表/锁 → 调用私有 |
| `runtime/RuntimeEnv.cj` | `deadline`、`fnTableBase` 改 TLS |
| `runtime/UserHelper.cj` | helper 栈改 TLS |
| `runtime/JitContext.cj` | 计数原子化 |
| `runtime/PromotionGroup.cj` | 引用计数原子化 |
| `backend/JitExecutor.cj` | 删 `envMtx`；`fnTableBase` 走 TLS |
| `JitFunction.cj` | 删 `callMtx`；`lastEscaped` 调用私有；`state/active` 原子化 |
| `CompilePipeline.cj` | 常量 pin / 窗口开合的调用方式适配 |

调用点（`HandleTable.xxx` 共 64 个文件）**不需要改**：静态 API 保留，内部按调用/线程路由。

## 5. 实施阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| **P0** | 存储选型 spike：分块 vs 预分配；「有活跃窗口时不搬迁」机制 | 结论写入 D3；内存/吞吐数据 |
| **P1** | 窗口切片 + 线程私有窗口栈 + `IterTable` 调用私有 + 计数原子化 | 两线程各自分配/遍历互不清窗；句柄账目独立 |
| **P2** | 三项环境改 TLS，删 `envMtx` | A 的 deadline 不再误中断 B；B 的长调用不被截断 |
| **P3** | 删 `callMtx`；`lastEscaped` 调用私有 | 4 线程 × 500 次同单元调用与串行逐位一致 |
| **P4** | 跨线程包装 + `PromotionGroup` 原子化 | A 建包装、B/C 调用、D 释放；计数归零 |
| **P5** | `state/active` 原子化；并发 `unload` | 在飞完成、新调用 19、超时回退 |
| **P6** | 全量 + 基准 + 泄漏 + 文档 | 8 线程 ≥ 5× 单线程；`liveCount`/`mallocCount` 回基线 |

## 6. 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 活跃窗口期间底层数组搬迁 | 并发写丢失 / 读到旧数组 | P0 定选型；分配器在切片分配前预扩容，或分块定长 |
| 槽位回收与在飞句柄竞态 | 类型混淆 | 槽只属一个切片；保留 `gen` 校验；回收只由切片 owner 发起 |
| 提升/释放跨线程 | 计数错乱、早释放 | `PromotionGroup` 原子引用计数 |
| 单线程回归 | 结果/错误码变化 | 全量对拍；单线程路径保持同一分配顺序 |
| 性能不达预期 | 并发退化 | P6 基准 2/4/8 线程；回看分配器争用与 false sharing |

## 7. 测试计划

| 用例 | 断言 | 阶段 |
| --- | --- | --- |
| `concurrentWindowsDoNotInterfere` | 2 线程各 200 次分配型调用，账目独立、结果正确 | P1 |
| `iterTablePerCallIsolation` | 两线程各遍历 Map 1000 项，结果正确、游标互不可见 | P1 |
| `deadlineIsThreadLocal` | A 带 10ms deadline，B 长调用不被中断；A 按时中断 | P2 |
| `sameUnitParallelCalls` | 4 线程 × 500 次同单元，结果/错误码/site 与串行一致 | P3 |
| `wrapperCrossThread` | A 建包装 → B/C 调用 → D `unloadFn`；无 UAF | P4 |
| `unloadDuringParallelCalls` | 并行中 `unload(timeout)`：在飞完成、新调用 19、超时回退 | P5 |
| `parallelThroughput` | 1/2/4/8 线程；8 线程 ≥ 5× 单线程 | P6 |

门槛：全量零失败；单线程路径与 `9357e98f` 逐位一致；无句柄/内存泄漏。

## 8. 与现有契约的关系

- **不变**：ID/gen 布局与「提升 ID 不变」；`unload`/`unloadFn` 语义；`CompileCache` 键与命中规则；
  错误码与 site；单线程行为。
- **变化**：并发不再串行；`deadline` 从「进程级」变「线程级」（并发语义修正）；
  `IterTable` 从全局表变调用私有（游标本就不跨调用，外部不可见）。
