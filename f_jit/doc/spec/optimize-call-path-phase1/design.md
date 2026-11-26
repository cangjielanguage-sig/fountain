# Design

## Context

`f_jit/doc/optimize-call-path.md` 的 §1 给了五条不可协商的硬规则，本设计的每个决定都必须能回溯到其中一条：

1. 先基线（同一 commit、同一指标 ≥5 次）后改码；
2. 一项一改、单独提交、可 `git revert`；
3. 保留 = 目标指标中位数提升 ≥ MOV **且** 其它指标回退 ≤2% **且** 全量零失败；
4. 达不到就回滚，并在文档 §7 记「无效 + 数据」；
5. 共享 7 核 VM 只作初筛，`8 线程 ≥5×` 必须在专用 ≥8 物理核机器复测。

当前执行路径上的三处短临界区（`optimize-call-path.md` §4 的 P1.1–P1.3）：

| 编号 | 位置 | 现状 | 每次调用的代价 |
| --- | --- | --- | --- |
| P1.1 | `runtime/HostCall.cj:217-269` | `Mutex` + 两张 `HashMap<UInt64, …>` | `free` 必进锁（`runtime/JitContext.cj:178-182` 调 `clear`），异常发生时再进 1–2 次 |
| P1.2 | `runtime/HostField.cj:94-111` | 锁内拷贝 bucket 到新 `ArrayList` | 一次锁 + 一次分配 + 一次遍历 |
| P1.3 | `JitFunction.cj:183-197/216-272/321-341`，`EscapedClosure.cj:29-43` | 单 `mtx` 同时守 `state/active/escaped/cacheKey/release` | `enter` + `exit` 各 1 次锁；包装再叠一层状态机 |

`isJitBacked` 未在吞吐基准中断言（`ParallelThroughput_test.cj:47-85` 只打印），所以 734 ms / 2M 次的
`S*` 数据**可能来自解释器**——这决定了 T0 必须先补观测，否则后续「锁的收益」测的是错误的对象。

## 结论（数据定稿，2026-11-26）

| 项 | 目标指标 | 基线 → 改动后（5 次中位数） | 判定 |
| --- | --- | --- | --- |
| P1.1 HostFault TLS | Q4 | 195595 → 444715 calls/s（+127.4%） | **keep** |
| P1.2 HostField 快照 | F1/F4 | 848/1710 → 507/219 ns（−40.2% / −87.2%） | **keep** |
| P1.3 生命周期原子化 | Q4/L1/S4 | 475096/5180/2.22 → 480830/5175/2.00（+1.2% / −0.1% / −9.9%） | **revert** |

P1.3 的代码、测试与 `enterPauseHook` 已全部回滚；D3 保留为「此路不通」的分析记录。
剩余瓶颈更可能在每次调用的窗口开合/分配锁，而不是 `enter/exit` 两把锁——留待 Phase 2 验证。

## 测量协议（T0，不参与 keep/revert）

### 指标与场景

| 代号 | 定义 | 采集 | 场景 |
| --- | --- | --- | --- |
| `Q1`/`Q4` | 短调用吞吐（calls/s，单线程/4 线程） | `CallPathBench_test` B1 | 单元 `{ n: Int64 => n + 1 }`，固定调用次数，`Q = 次数 / 墙钟` |
| `L1` | 单次短调用延迟（ns/call） | B1 单线程结果取倒数 | 同上 |
| `F1`/`F4` | 宿主字段读循环（ns/op，单线程/4 线程） | B2 | 单元内循环 `obj.field` N 次（H64 命中值型字段） |
| `A4` | 分配型单元加速比 | B3 | 每轮 `any_box` / 容器构造，单线程 vs 4 线程墙钟 |
| `C1` | `JitContext.create + free` 单次成本（ns） | B4 | 直接循环 create/free，不经 JIT 调用 |

### 工具形态

- `CallPathBench_test` 是**非门槛**测试类：只 `println('CP-BENCH …')`，**不做任何时序断言**（构建机是共享 VM，时序断言必然假失败——`ParallelThroughput_test.cj:26-32` 已确立此约定）。
- 每个场景只跑一个 `@TestCase`，一次执行内完成「预热 + 测量 + 打印原始值」，避免跨用例的冷启动差异。
- 打印格式固定为 `CP-BENCH scene=B1 metric=Q1 value=… unit=calls/s`，便于人工抄进文档 §6/§7；不引入解析器。
- B4 用 `JitContext.create(hwBase: 0, hwCap: 128, fnId: 0, dbgBase: 0)` + `JitContext.free`，**不碰** `HandleTable`，使 `C1` 只反映 ctx 的 malloc/free + 计数成本。

### 噪声门槛

对每个指标在同一 commit 上采 5 次得 `x1…x5`，中位数 `M`，相对离散度 `d = max|xi−M|/M`：

- `MOV = max(3%, 2d)`；
- 5 次离散度 `d ≥ 10%` ⇒ 工具不稳定，**先修工具，不进入任何优化**（`optimize-call-path.md` §4 T0 的保留条件）；
- 判定一律用中位数，不用单次最好值。

### `isJitBacked` 的处理（避免制造已知红）

`ParallelThroughput_test` 增加打印 `PAR-BENCH jitBacked=…`。**打印恒有**；`@Assert(f.isJitBacked(), true)`
只在探测结果为 `true` 时固化：

- 若为 `false`，说明基线跑的是解释器路径，此时 `S2/S4/S8` 不能代表机器码并行度。按文档 §8「先查
  `isJitBacked` 与解释器回退，再谈锁」，把该事实写入 §7 并把「机器码路径为何不可用」升级为独立问题，
  **不**把断言加进去制造一条已知红（否则「全量零失败」这条保留条件永久不可满足）。

## 决策

### D1 HostFault：线程本地表，健康路径零锁零分配

`HostFault` 的读取方全在同线程：`record` 在 helper 的 catch 里（`HostCall.cj:77-80`、`HostField.cj:136-142`、
`UserHelper.cj`），`causeOf/exceptionOf/takeCause` 在 `JitReport.finish` 与桥的异常构造里，`clear` 在
`JitContext.free`。全仓 grep `HostFault\.` 的 15 处调用点没有一处跨线程。因此收窄为线程私有**不改变任何
现有可观察行为**，只是让「跨线程读 cause」从「碰巧能读到」变成「明确读不到」。

结构（把两张表合成一条记录，一次查找代替两次）：

```text
private class FaultEntry { text: String; ex: Exception }
private static let tls = ThreadLocal<HashMap<UInt64, FaultEntry>>()
```

- `record`：`tls.get() ?? 新建 HashMap` → `add(keyOf(ctx), entry)`；后写覆盖（同调用最后一次失败为准）。
- `causeOf` / `exceptionOf`：`tls.get()` 为 `None` ⇒ 直接返回 `None`（**不创建表**）。
- `takeCause`：取值后 `remove`；表空时不必删表（避免抖动）。
- `clear`：`tls.get()` 为 `None` ⇒ no-op。这条是健康路径的关键——**无异常时 `free` 不分配、不取锁**。

不变量：`create` / `record` / `free` 在同一线程（由 `callLocked` 的 try/finally 结构保证，
`JitFunction.cj:571-643`）。若出现「A 线程记录、B 线程 free」，A 的条目会残留，且 malloc 复用同一地址时
可能被读到——这是本设计唯一新增的失效形态，用「释放即清空」「线程本地不可见」两条用例钉住，并在
design 风险表登记。

## TDD 与验证策略（评审重点）

本变更包含两类工作，Red 的来源不同，必须在评审时确认：

| 项 | Red 来源 | 说明 |
| --- | --- | --- |
| P1.1 HostFault | **真实行为差**：旧全局表下「A 线程记录、B 线程以同一 ctx 查询」会读到 Some；新语义要求 None | 该用例在实现前必须失败；失败原因是断言不满足，不是编译错误 |
| P1.2 HostFieldTable | **无行为 Red**（纯性能重构） | 语义用例是 characterization 护栏，实现前后都应绿；keep/revert **只由 `F1/F4` 数据决定**。这是本变更显式声明的 TDD 例外：不为了制造 Red 而引入人为的行为变化 |
| P1.3 state/active | 已用 `enterPauseHook` 做确定性竞态 + 变异验证 | **数据不达标已回滚**：Q4 +1.2%、L1 −0.1%、S4 −9.9%，无指标达 MOV；钩子与测试一并删除，不留生产脚手架 |

> P1.2 的例外需要用户在评审时明确接受；不接受则本项不进入 apply。

### D2 HostFieldTable：不可变快照 + 无锁读

注册是冷路径（`Compiler.registerClass` / `ReflectRegistrar` / 手工注册），查找是热路径（H64/H65）。

```text
private class FieldSnapshot {
    let buckets: HashMap<UInt16, Array<HostFieldAccessor>>   // 值是不可变数组
}
private static let writeMtx = Mutex()
private static let current = AtomicReference<FieldSnapshot>(empty)   // 仅写者更新
```

- `register`：`synchronized(writeMtx)` 内做 COW——拷 `buckets`、只拷目标 index 的 `Array`、追加、构造新
  `FieldSnapshot`、`store` 发布。注册频率与单元数量同阶，O(n) 拷贝可接受。
- `find`：`current.load()` → `buckets.get(index)` → 逐条 `accepts(obj)`。**无锁、无拷贝、无分配**。
  旧写法里那个只为「锁外匹配」而存在的 `ArrayList` 拷贝（`HostField.cj:95-104`）整段删除。
- `accepts` 在 `load` 之后、任何锁之外求值 ⇒ 访问器内部重入 `register` 仍合法（文档要求「`accepts` 仍在锁外求值」）。
- `resetForTest`：`synchronized(writeMtx)` 内 `store(empty)`。测试必须先 join 工作线程再复位，
  避免旧快照跨测试存活（`optimize-call-path.md` §5 的要求）。
- **API 前置（2026-11-26 已核实，P0.1 仍需探针复验）**：本地 std 文档确认
  `AtomicReference<T>` 提供 `init(val)` / `load()` / `store(v)` / `compareAndSwap(old, new)`；
  `AtomicInt64.compareAndSwap(old, new)` 存在；`ThreadLocal` 写法与 `runtime/RuntimeEnv.cj` 一致。
  探针若与文档不符，停下来回报，**不自行发明**替代发布机制。

### D3 生命周期：原子量 + 双检（**评估后否决，未保留**）

> 本节保留为分析记录。实现与变异验证均通过，但 5 次复测无指标达 MOV（Q4 +1.2%、L1 −0.1%、
> S4 −9.9%），按 §1 硬规则回滚；代码、测试、`enterPauseHook` 均已删除。

`JitFunction.mtx` 现在同时守三类状态，只有第一类在执行路径上：

| 状态 | 路径 | 迁移后 |
| --- | --- | --- |
| `state` / `active`（单元与闭包） | 每次 `enter`/`exit` | `AtomicInt64`，无锁 |
| `escaped` 清单 / `escapedSeq` / `lastEscaped` | 仅 `retType=12` 收尾与卸载 | 仍在 `mtx` |
| `cacheKey` / `release` | 仅 `close` 终态 | 仍在 `mtx` |

进入（含包装）：

```text
enter:
  if (state.load() != 0) throw 19          // 快路径拒绝
  active.fetchAdd(1)
  if (state.load() != 0) {                 // 复读：关闭窗口
      active.fetchSub(1)
      throw 19
  }
exit: active.fetchSub(1)
```

包装实例对「单元状态」与「本闭包状态」各做一次同样的双检；任一失败时按相反顺序撤销已加的两个计数。
顺序固定为「先单元、后闭包」，进入与撤销严格对称。

卸载（CAS 决出唯一胜者）：

```text
close(timeoutMs):
  if (state.compareAndSwap(0, 1)) {        // 胜者
      poll active.load() == 0  直到超时
      超时 → state.compareAndSwap(1, 0); return false
      state.store(2)
      synchronized(mtx) { 逃逸闭包级联置 2 / 取 cacheKey 逐出 / 取 release }
      锁外：groups.releaseAll()；release()
      return true
  }
  // 败者：只等终态，不碰资产
  if (state == 2) return true
  poll state == 2 直到超时；到达 → true，否则 → false
```

- 败者**不复位**状态：现在两条 `close` 都会往下走并各自执行 `release`，属于事实上的双重释放风险；
  CAS 语义把它收紧成「唯一胜者 + 其余等待」，与规格 `卸载状态机与资产清点` 的「重复卸载 SHALL 幂等」一致。
- 双检是唯一防止「close 与晚到 enter 竞态」的机制，所以**必须做变异验证**：去掉复读后，晚到 enter 会
  在 `state=1` 之后计数成功，卸载方可能已排空并释放代码内存 ⇒ 用例必须变红；不变红说明用例没有覆盖到。

### D4 顺序、提交与回滚

- 顺序固定：T0 → P1.1 → P1.2 → P1.3（P1.1 必须先于将来的 ctx 池化，本次不含池化）。
- 每个 P1.x 一个独立提交，提交信息带指标数据；回滚 = `git revert <该提交>`，不留半成品。
- 三项同属一个 Phase 但**分别判定**：任何一项 revert 不影响其它两项的结论。

### D5 备选方案与否决理由

| 备选 | 否决理由 |
| --- | --- |
| 把 `HostFault` 塞进 ctx 的 64 B 布局 | ctx 布局是机器码 ABI 契约（`JitContext.cj:81-96`），改布局要动后端与格式 |
| `HostFieldTable` 用读写锁代替快照 | 读仍是原子操作 + 可能的写者饥饿；且 `accepts` 在锁外求值的要求不变，快照更简单 |
| 生命周期改用单把 `Mutex` + 自旋锁 | 自旋锁在 8 线程超订时更差；原子量零阻塞 |
| 顺手把 `SignatureTable` / `AdapterRegistry` 一起 COW | 文档 P3.2 明确「只在 profile 指向此处时才做」，且依赖卸载可见性验证（P3.3） |
| 顺手做 ctx 池化 | 依赖 P1.1，且要求先改 `NativeMem` 计数口径（规格变更，需独立 OpenSpec） |

## 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| TLS 表按 ctx 地址记账，若 create/record/free 跨线程 | 原线程残留条目，地址复用后可能读到旧 cause | 钉住「create/record/free 同线程」不变量；新增「线程本地不可见」「释放即清空」用例 |
| 快照发布缺内存可见性（非原子写引用） | 读方看到半构造的 `FieldSnapshot` | 只用 `AtomicReference` 发布整对象；核实 API 不可用则停止（D2 前置） |
| 原子计数漏减 / 多减 | 卸载永久挂死，或早释放导致 UAF | 进入/撤销严格对称；`exit` 与 `enter` 成对；并发用例 3 轮 + 变异验证 |
| CAS 败者等待策略写错 | 超时路径把状态误置终态 | 败者只读不写；超时路径的复位只由持有者执行 |
| 共享 VM 噪声导致误判 keep | 保留了一个无收益的改动 | 5 次中位数 + `MOV = max(3%, 2d)`；`d ≥ 10%` 先修工具；达标结论在专用机复测 |
| 基准本身不稳定 | 无法判定任何一项 | T0 的保留条件：工具连续 5 次离散度 < 10% 才进入 P1 |
| 删除 bucket 拷贝后语义漂移 | 同 index 多类命中顺序变化 | 快照保留 `Array` 的注册序；`find` 逐条 `accepts`，顺序与旧实现逐字一致；既有 `HostFieldGet/Set_test` 全绿 |

## 实施顺序

```text
T0   CallPathBench_test（B1–B4）+ ParallelThroughput 观测
     ↓ 5 次基线、算 MOV、写 §6/§7
P1.1 HostFault TLS        → 基线 → 改 → 复测 Q1/Q4/L1/C1 → keep/revert（独立提交）
P1.2 HostFieldTable 快照  → 基线 → 改 → 复测 F1/F4（≥10%） → keep/revert（独立提交）
P1.3 state/active 原子化  → 基线 → 改 → 变异验证 → 复测 L1/Q1/Q4/S4 → **revert（无收益）**
     ↓
收口：全量零失败、决策日志回填、文档状态更新
```
