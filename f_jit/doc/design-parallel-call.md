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

### D2 每调用独占窗口记账

- 窗口从「全表一个」变为「每次调用一份互不重叠的槽集合」。
- **不要求索引连续**：运行期没有任何 helper 用 `hwBase/hwTop` 反推槽地址（已逐点核对），
  它们只作容量账。因此窗口槽可以来自共享空闲表；`resetWindow` 按「本窗口登记且代数仍匹配」
  逐槽释放。这样既保留「回收后复用同一槽」的既有语义（`slotCount` 不虚增），
  也避免连续区间被逃逸槽切碎后的碎片化。
- `ctx.hwBase/hwCap/hwTop` 仍是本窗口账目的真值（不再是全局窗口的镜像）。
- 重入（宿主闭包回调再进 JIT）在同一线程再压一层，窗口栈改**线程私有**。
- `resetWindow` 只释放**本窗口登记**的路径 C（`append`）槽；路径 B 的 pin 是桥侧资产，
  跨调用存活，由 `CallMarshal.cleanup` / 宿主归还。

### D3 槽存储的并发安全：去锁靠「所有权 + 发布后不可变」

**现状比预想更重**：`HandleTable` 有 29 处 `synchronized(mtx)`，连纯读也在锁内——
`getAny`（`:572`）、`getAs`（`:589`）、`isType`（`:740`）、`tagOfHandle`（`:776`）；
`fetch*` 也都经 `fetchAny` 加锁。`pin` 更是在锁内**全表线性扫描**去重（`:285-330`，1M 槽位下是 O(n)）。

⇒ 只切窗口、不动读路径，结果是「每个 helper 一次全局锁」，比现在（每次调用一次）更糟。

去锁依据不是「数据在线程本地」，而是**所有权 + 发布后不可变**：

| 槽类别 | 谁写 | 读取是否需要锁 | 理由 |
| --- | --- | --- | --- |
| 窗口槽 | 仅本次调用的 owner 线程 | 否 | 切片独占；其他线程拿不到该 ID |
| 常量槽 | 编译期一次 | 否 | 发布后内容不变 |
| 提升槽 | `PromotionGroup`（引用计数） | 否 | 存活期内容不变；归零释放时已无合法读者 |

仍需加锁的只剩**冷路径**：切片分配、槽回收、常量 pin、表增长（每次调用/每次编译一次）。
`alive/gen` 的更新需原子发布，避免读到「已释放但 gen 未更新」的中间态。

#### P0 存储选型结论（已实施）

| 方案 | 结论 |
| --- | --- |
| 预分配整表 | **否决**：`capacityLimit` 运行期可调；按上限预分配 1M 槽约 24 MB（8 个数组），按首用值预分配则在调大时被迫重分配 ⇒ 与在飞读者竞态。 |
| 分块（1024 槽/段） | **采用**：目录定长 4096 项（覆盖 4M 槽，128 KB 指针），段惰性分配、地址永不变化；增长 = 给目录挂一段新数组。 |
| 「有活跃窗口不搬迁」机制 | 目录与段都不重分配；槽索引只由全局高水位 `totalSlots` 增长。活跃窗口的读路径只读段指针与段内数组，不受增长影响。 |

代价：每次槽访问多一次「目录索引 + 段内偏移」；收益是读路径完全去锁，且任何时刻都不搬迁已有槽。
（P6 基准再量化；若成为瓶颈，可调大段尺寸或加一级线程本地段缓存。）

### D3b 数据放在哪：线程上下文 vs 共享表

| 数据 | 位置 | 理由 |
| --- | --- | --- |
| 窗口记账（base/top/used/slots、窗口内去重表） | **线程上下文** | 只有本线程使用 |
| 槽数组（对象引用） | **共享表** | 提升要求 ID 不变 ⇒ 必须全局可解析 |
| 常量槽 | 共享只读区 | 编译期一次写入，跨线程共享 |
| 提升槽 | 共享区 | 包装要跨线程调用 |
| `UserHelperTable.stack` | **线程上下文** | 纯调用级 push/pop，条目不可变 |

即：**能搬的搬（记账、helper 栈），必须共享的留（槽数据）**；共享部分靠所有权与只读发布去锁，
而不是靠「每个线程一份副本」。

### D3c `pin` 去重范围

`pin` 现在对每个实参在全局锁内扫描整表。改为：
- **窗口内去重**：线程本地 map（对象身份 / 规范键），只覆盖本次调用的实参；
- **常量**：`pinConst` 走全局锁（编译期冷路径）。

规格要求的「同一对象在实参、闭包内引用与返回值带回时保持身份」是**调用内**语义，窗口内去重足够。

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
| `runtime/HandleTable.cj` | 窗口切片化 + 分配器 + **读路径去锁** + `pin` 去重范围收窄（最大一块） |
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
| **P1** | 窗口切片 + 线程私有窗口栈 + 读路径去锁 + `pin` 去重收窄 + `IterTable` 调用私有 + 计数原子化 | 两线程各自分配/遍历互不清窗；并发读不争全局锁 |
| **P2** | 三项环境改 TLS，删 `envMtx` | A 的 deadline 不再误中断 B；B 的长调用不被截断 |
| **P3** | 删 `callMtx`；`lastEscaped` 调用私有 | 4 线程 × 500 次同单元调用与串行逐位一致 |
| **P4** | 跨线程包装 + `PromotionGroup` 原子化 | A 建包装、B/C 调用、D 释放；计数归零 |
| **P5** | `state/active` 原子化；并发 `unload` | 在飞完成、新调用 19、超时回退 |
| **P6** | 全量 + 基准 + 泄漏 + 文档 | 8 线程 ≥ 5× 单线程；`liveCount`/`mallocCount` 回基线 |

### D3d 热路径写入台账：频繁 ≠ 需要锁

`resetWindow` 每次调用按「已分配槽数」逐个写 `alive/objs/gens` 并 `freeSlots.add`；
`newSlotLocked` 每次分配 `freeSlots.remove` 或 `objs.add`（8 个数组同增）。所以下列结构**确实高频**：

| 结构 | 每调用写次数 | 写者 | 去锁方式 |
| --- | --- | --- | --- |
| 槽体（`objs/tags/alive/constFlags/escapeFlags/frozenFlags`） | 分配数 × 2（分配 + 收尾） | **仅本调用 owner** | 所有权 ⇒ 无锁 |
| `gens` | 分配数（收尾 +1） | owner；逃逸槽由 `PromotionGroup` | 原子 u16 或「先失效后发布」 |
| `windowSlots` / `windowBase/Top/Used` | 分配数 + 收尾 | 仅 owner | 搬线程上下文 |
| **`freeSlots`** | 分配数 × 2（pop + push） | **所有线程** | **必须切片私有**；全局只回收整段 |
| 索引空间（`objs.size` / `add`） | 仅 free list 空时 | 所有线程 | 切片分配时预取；增长走冷路径 |
| 8 个数组增长 | 摊还偶发 | 所有线程 | 冷路径加锁；**活跃窗口期间禁止搬迁** |

结论：**高频的是「槽体写入、gen、free list」**，但前两者写者唯一（调用 owner），不需要锁；
真正会被所有线程同时撞的只有 **`freeSlots`** 和**数组增长**。
⇒ `freeSlots` 必须从全局栈改为「每切片 free list + 全局切片池」，否则 pop/push 就是新的全局锁。

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

## 9. 实施状态（2026-11-26）

已落地（P0 + P1 主体 + P2 + P3）：

- **P0 存储选型**：分块存储（1024 槽/段，定长目录），见 D3「P0 结论」。
- **P1.2 / P1.3**：窗口记账与窗口栈改线程私有；`ctx.hwBase/hwCap/hwTop` 是每线程真值。
- **P1.2b**：`getAny/getAs/isType/tagOfHandle/tagOrZero/fetch*` 全部改为无锁读。
- **P1.2c**：`pin/pinHostObject/pinHostClosure` 去重收窄到**本窗口登记的槽**（路径 C + 路径 B），
  删除全局锁内的全表线性扫描。
- **P1.4**：`IterTable` 改线程私有（`ThreadLocal<IterState>`），锁随表消失。
- **P2**：`deadline` / `fnTableBase` / helper 栈改线程私有，删 `JitExecutor.envMtx`；
  `invokeOff` 对函数表基址做保存/恢复（重入不再把外层清 0）。
- **P3**：删除 `callMtx`；`callForFn` 改读本次调用的 `CallOut.escaped`，不再依赖单元级 `lastEscaped`
  （字段只保留给 `lastEscapedClosure()` 单线程诊断访问器）。并发调用从此真正并行。
- 新增 `WindowIsolation_test`（3 条）：并发窗口记账独立、`resetWindow` 不误杀已被复用的槽、
  迭代器表线程私有；三条均做了**变异验证**（改回全局实现即变红）。

未完成（后续阶段）：

- **P1.2d**：`freeSlots` 仍为全局表 + 短锁（当前只保护分配/回收，不在执行路径上串行化）。
- **P1.5**：`NativeMem.mallocCount/freeCount` 仍是普通静态计数（诊断口径，暂未原子化）。
- **P4–P6**：跨线程包装、生命周期、基准。

验收：全量 **1184 用例 / 1184 通过 / 0 失败**；单线程路径行为不变。
新增 `ThreadLocalEnv_test`（3 条，三处 TLS 同时改回全局时三条全红）。
P3 后 `ParallelCall_test` 在真实并发下连续 3 轮 6/6，`CallForFnConcurrency_test` 2/2。
