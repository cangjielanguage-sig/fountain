# Design

## Context

### 起点

- 本变更在工作树 `f_rule`（分支基于 `sts/1.3.x`）。`f_rule` 目录下只有 `cjpm.toml`、`README.md`、`doc/01~10`；
  `src/` 不存在，`cjpm build` 目前只是"空模块"。
- `f_rule/cjpm.toml` 已声明 `f_base / f_collection / f_concurrent / f_egraph / f_excel / f_jit / f_log /
  f_regex / f_util` 的路径依赖，**缺 `f_app`（`Initializer`）与 `f_ticktock`（`JoinTask` 超时）**。
- 仓库根 `.modules` 的 `[include]` **没有** `f_rule`，因此本模块当前不会被发布。

### 上游真实能力（已核对源码，不是文档推测）

| 上游 | 事实 | 对本变更的影响 |
|---|---|---|
| `f_egraph` | `ImmediateFlow.emit(eventType:name:data:)` 无 `session` 参数，内部新建 `DataEvent` 用随机 UUID；`multiEventTaskBody` 只透传 `eventType/name/data` | session 必须由载荷承载（`RuleEnvelope`，D8） |
| `f_egraph` | `ImmediateDispatcher.dispatch()` 命中 `EndExecutor` 立即 `return`；**剩余队列事件不清空**，会在下次 `start()` 被重放 | 扇出必须 `JoinTask`，且构建期拦截（D8）；比"丢弃"更隐蔽，需专门回归用例 |
| `f_egraph` | `TaskExecutor.execute` 直接调用 `task(event)`，**不捕获异常**；错误路径是"返回 `ErrorEvent` + `registerError()`" | 动作/表达式异常不得穿透到事件循环（D7、D6） |
| `f_egraph` | `Task.exec(e): Event`，`registerTaskByImmediateFlow` 只把 `data` 传给子流程 | `RuleTask` 输出必须重新包信封 |
| `f_jit` | 只有 `Compiler.compile(source)`，要求**单个 lambda 字面量**；没有 `eval`/表达式 API | `JitExpression` 需自己包装 lambda（D7） |
| `f_jit` | `call<T>` 要求 `T` 精确等于编译单元的返回类型；`Option<T>` 无 `LocalType`；`@JitBind` 成员返回 `Any`/`Option` 被跳过 | 动态事实 `get(): ?Any` 无法进 JIT → 走内置解释器（D7） |
| `f_jit` | `CompileCache` 是进程级静态、键只含源码 + 模式 + 版本 + `strictFp`，不含注册类型集合 | 生成源码必须包含完全限定类型名，否则不同规则集共用同一编译结果会串类型 |
| `f_jit` | 所有 JIT 调用由进程级 `callMtx` 串行 | 脚本条件天然串行；议程本就单线程，可接受；并发会话会排队（风险） |
| `f_concurrent` | `ConcurrentSkipListMap<K,V>` 存在，`K <: Comparable<K>`；有序区间 API 是 `tailer/header/sub`，**没有** `ceiling/floor/firstKey` | 范围索引必须按 `sub/tailer/header` 设计（D4） |
| `f_excel` | `ExcelDocument(Path)`、`sheet(name): ?Worksheet`、`cell(row, col): ?CellValue`、`mergedValue`、`CellValue` 八变体、`ExcelSheetStream.open(Path)` + `rows(sheet): ?RowReader` | XLSX 载体只做映射，不另写 OOXML（D9） |
| `f_app` | `Initializer` 是 **interface**（`name` / `dependencies` / `initialize()` / `start()`），`static init()` 中 `InitializerCollection.register(...)` | `RuleInitializer` 按既有模式实现 |
| `f_regex` | `"pat".regex().matches("s")` 为整串匹配；无 `fullMatch` | `Matches` 算子直接用 `matches` |
| `f_log` | 无 `Log` 门面；`LoggerFactory.getLogger<T>()` + `logger.info{...}` | 日志统一走 `LoggerFactory` |

### 环境与约定

- 平台：Linux x86_64/aarch64 上 `f_jit` 有机器码后端，ohos/macOS/Windows 走解释器（功能等价）。
- 项目约定：新功能 TDD、`*_test.cj` 与被测代码同目录、`cjpm test` 全绿才提交、不在仓库外建单文件测试。
- 不修改根 `cjpm.toml` 与根 `src/` 聚合 shim（与 `add-f-jsonrpc` 的处理一致）。

## Goals / Non-Goals

**Goals**

- 交付 `doc/10-roadmap.md` 的 M0~M7，公开 API 与 `doc/08-api.md` 一致（除本文件显式记录的偏差）。
- 事实双形态、按空间分片的 Rete、议程、流程编排、三载体决策表全部可用且有单元测试。
- 规模不设上限：范围索引用 `ConcurrentSkipListMap`，配置 1000 规则 / 10000 事实的门禁。
- 不改 `f_egraph`，用 `RuleEnvelope` 解决 session 透传，用 `JoinTask` 解决扇出。

**Non-Goals**

- 规则持久化、分布式执行、可视化编辑器、事务回滚、`accumulate` 聚合。
- Rete 的增量规则增删（改规则按分片重建）。
- `f_egraph` 的 E1~E4 扩展。
- 决策表 XLSX 写回。

## Decisions

### D1. 包结构：12 个包，根包只做重导出

> **实施后修订**：D1 原写「9 个包、RuleEngine/RuleSession 在根包」。实施中因包循环
> （`flow` 要引 `RuleEngine`，而根包要重导出 `flow`）下移出 `engine` 与 `runtime` 两个包，
> 决策表期间又新增 `table` 的装配层依赖。最终结构如下，公开 API 未变（根包重导出）。

```
f_rule/src/
├── rule.cj                 fountain::f_rule            门面重导出 + RuleInitializer
├── exception/              fountain::f_rule.exception  RuleException / RuleErrorCode
├── fact/                   fountain::f_rule.fact       Fact/TypedFact/DynamicFact/FactSchema/FactSpace/FactBase/ValueKey
├── condition/              fountain::f_rule.condition  Operator/Operand/Constraint/Pattern/JoinConstraint/ConditionExpr/JitExpression/EvalOutcome
├── runtime/                fountain::f_rule.runtime    RuleRuntime（共享 Compiler / 全局配置，最底层）
├── rule/                   fountain::f_rule.rule       Rule/RuleBuilder/RuleSet/RuleSetBuilder/Validator/
│                                                       ActionContext/ClosureAction/TableAction/ScriptAction/
│                                                       RuleFailureGuard/TableSource/ConflictResolver
├── rete/                   fountain::f_rule.rete       Root/Alpha/Beta/Token/Terminal/NetworkBuilder/ReteNetwork/SessionNetwork
├── agenda/                 fountain::f_rule.agenda     Activation/Bindings/Agenda/ConflictResolver 实现/CycleDetector
├── engine/                 fountain::f_rule.engine     RuleEngine/RuleSession/EngineOptions/FireResult
├── flow/                   fountain::f_rule.flow       RuleFlow/RuleSetFlow/ResolveTask/JoinTask/RuleEnvelope/FlowContext/RuleTask
├── table/                  fountain::f_rule.table      DecisionTable/HitPolicy/CsvTableParser/XlsxTableParser/TableCompiler/TableExecutor
└── test/                   fountain::f_rule.test       NaiveMatcher / PropertyGen（仅测试与差分用）
```

- 子目录包名必须与目录路径一致（与 `f_jit` 的 `base/`、`backend/` 相同），`cjpm` 自动识别，无需额外 `cjpm.toml`。
- `RuleSet` 的**构建器**（`RuleSetBuilder`）放 `rule/`，模型与校验规则同包，避免循环依赖。
- 包依赖单向：`runtime → exception → fact → condition → rule → (rete, agenda, table) → engine → flow`；
  子包**禁止** `import fountain::f_rule.*`，否则根包无法重导出上层包。
- `src/test/` 的类型声明为 `public`（跨包测试无法访问 `internal`），但在 README 与 `@IgnoreJitBinding` 中标注
  "仅测试使用"，且不进入根包重导出。这是对 `doc/09` §7"internal"的显式偏差，原因是仓颉的 `internal`
  是模块级、跨包不可见，而差分测试需要在 `rete` 包外构造规则与事实。

### D2. 事实双形态与不可变契约

`Fact` 接口保持 `doc/02` §2 的三成员（`typeTag`、`get`、`has`）。`TypedFact<T>` 持有原对象引用与 schema，
`get` 直接调闭包；`FactSchema<T>` 额外记录 `hostTypeName = TypeInfo.of<T>().qualifiedName`，供 D7 拼 lambda 类型。

`DynamicFact` 用 `HashMap<String, Any>`，`assert` 时 `freeze()`；支持 `Array<Any>` / `Set<Any>` 的浅归一。

**冲突裁决**：`doc/09` F-04 要求"同一对象重复 assert 抛 `DUPLICATE_FACT`"，而 `doc/04` §6.1 要求
`AlphaMemory.add` 幂等。两者不矛盾：`FactBase` 层对同一 `Fact` 实例的重复 `assert` 抛错；
网络层对同一 `FactHandle` 的重复传播幂等。实现时 `FactBase` 记录 `identity -> handle` 的弱引用表，
`retract` 后清除。

`FactHandle` 的 `hashCode` 只用 `(space, id)`；`typeTag` 参与 `toString` 与桶定位，不参与相等性。

### D3. 空间模型与运行态分层

```
RuleSet
├── FactSpaceRegistry (冻结后只读)
│   └── FactSpace(id) → typeTag → TypeDescriptor(fields, fieldTypes, getter, hostTypeName)
├── 每空间一个 ReteNetwork（结构：节点 + 共享键，进程内共享）
└── RuleEngine
    └── RuleSession(session)
        ├── SessionRuntime
        │   ├── SessionNetwork(space) → (space, session) 的 alpha/beta memory
        │   └── Agenda（session 级、跨空间统一排序）
        └── FactBaseView(space) → FactBase(space, session)
```

`ReteNetwork` 与 `SessionNetwork` 分离是关键：网络结构只构建一次，memory 按会话隔离，
否则 `(space, session)` 隔离无法成立。

`FactSpace` 不持有事实实例，只持有类型描述；`FactBase` 只做存储与 id 分配，索引归属 memory（避免双索引不同步）。

### D4. 范围索引：`ConcurrentSkipListMap<RangeKey, FactHandle>`

`doc/04` §7.1 的 `SortedIndex` 由 `f_concurrent.ConcurrentSkipListMap` 实现，**不用"有序数组 + 二分"**：

```cangjie
// ValueKey 全序：域序（Number < Text < Bool < Time < List）→ 域内比较
class RangeKey <: Comparable<RangeKey> {
    let key: ValueKey
    let id: Int64          // FactHandle.id，允许同值多事实
    func compare(other: RangeKey): Ordering
}

class AlphaMemory {
    let eqIndex: HashMap<String, HashMap<ValueKey, ArrayList<FactHandle>>>
    let ordIndex: HashMap<String, ConcurrentSkipListMap<RangeKey, FactHandle>>
    let nullSet: HashSet<FactHandle>
}
```

- 探测映射（`tailer(low, including:)` / `header(high, including:)` / `sub(low, high, includingMin:,
  includingMax:)`）直接对应 `Gt/Ge/Lt/Le/Between`，无需自研跳表。
- `ValueKey` 必须实现 `Comparable<ValueKey>` 且**全序**，否则同一字段混类型时跳表会崩；跨域的排序算子仍在
  算子层抛 `TYPE_MISMATCH`，索引层只负责定位。
- 不设规模阈值、无"索引过大退化"分支；插入/查询复杂度 O(log n)。
- 迭代是弱一致的，但 `(space, session)` 内传播单线程，不存在并发修改，弱一致不产生可见影响。

### D5. 节点共享与签名归一

`AlphaSignature = (typeTag, field, op, ValueKey(右值), ?rightField)`；`JoinSignature =
(leftNodeId, rightAlphaId, 排序后的 joins)`。约束在入签名前**排序**（先算子类别、再字段名），
保证同一集合产生同一签名；`In` 展开为多个 `Eq` 加聚合节点。

`JoinPlan` 在构建期按"左集合大小、索引覆盖、算子类型"确定并冻结，运行期不重新决策。
`alpha/beta` 的传播顺序按 `node.id` 升序。

### D6. 议程：惰性堆

`Agenda` 内部为二叉堆（`ArrayList<Activation>` + 比较器），另维护
`index: HashMap<(space, ruleId, bindings), Activation>` 去重与 `firing: Bool` 重入保护。

`Activation` 持有所在终端令牌的引用；令牌撤回时 `Activation.valid` 变 false，`popValid()` 跳过并丢弃。
`remove` 只改有效性位，不做队列中间删除。`NoLoop` 的 `firedSet` 在 `fire` 结束时清空。

### D7. 表达式：把 `f_jit` 的 lambda 约束适配到规则 DSL

`f_jit` 没有表达式 API，且 lambda 形参必须带类型。因此：

- `JitExpression.of(source)`：要求 `source` 是**完整 lambda**（`{ o: Order => o.amount > 200 }`），
  供 `RuleBuilder.where(source:)` 使用；`f_rule` 只校验 `{` 开头并把 `f_jit` 的 `site/report` 包进
  `RuleException(SCRIPT_COMPILE)`。
- `JitExpression.ofExpression(source, bindings: Array<(binding, hostTypeName)>)`：供决策表 `expr` 列使用，
  由 `FactSpace` 的类型描述提供 `hostTypeName`，拼成 `{ b1: N1, b2: N2 => <source> }` 再编译。
  **生成源码含完全限定类型名**，顺带避开 `f_jit` 进程级编译缓存"键不含注册类型集合"的坑。
- 动态事实（`DynamicFact`）的 `get()` 返回 `?Any`，`f_jit` 无法表达，因此其脚本条件**整体**走内置解释器：
  这是能力性降级，构建期记 WARN；语法/类型错误仍抛 `SCRIPT_COMPILE`，不静默降级。
- 内置解释器：递归下降，优先级 `|| < && < ! < 比较`，只允许字段访问、字面量与 10 个白名单函数；
  求值异常 → `Unknown`；`EngineOptions.expressionTimeout` 只在 JIT 路径通过 `CallContext` 生效，
  解释器路径用节点计数上限（默认 1e6）近似。
- 运行期连续失败 100 次的规则置为 disabled（`Rule.disabled` 运行态标志），后续不再产出激活。

### D8. 流程编排：不改 `f_egraph`

- `RuleEnvelope` 作为所有 f_rule 事件载荷的唯一外壳，`from/wrap` 见 spec；下游只读信封，不读 `Event.session`。
- `FlowContext` 用 `ThreadLocal` 绑定，任务入口 `attach`、`finally` 中 `detach`。
- `RuleSetFlow.build()` 做可达性检查：从每个 `ResolveTask` 的 `producing` 事件出发做 BFS，
  遇到 `End`/`registerEnd` 的边即抛 `FANOUT_WITHOUT_JOIN`；同时校验 `JoinTask.branches` 两两不重叠。
- `RuleSetFlow.fanout` 检查分支首规则空间，出现同空间即抛 `SAME_SPACE_FANOUT`。
- `JoinTask` 的 `timeout` 通过 `f_ticktock.DelayedTicktockTask` 子类实现一次性延迟任务；
  `Ticktock.getInstance()` 返回 `None` 时构造期 WARN 并关闭超时（不静默丢状态）。
- **残留事件**：由于 `dispatch()` 不清空队列，`RuleSetFlow` 在 `start()` 处不做额外处理，但测试
  P-05b 专门锁定"缺 Join 时第二次 `start` 会消费残留事件"这一上游行为，防止未来误判。

### D9. 决策表：类型来源与载体映射

文档没有回答"`when.<field>` 属于哪个 `typeTag`"。本设计补 `factType` 表属性（CSV `# factType:`、
XLSX `_meta`），未声明时若空间只有一个类型则自动取，否则 `TABLE_INVALID`。

- 每行编译成 **单模式**规则：`Pattern(factType, binding)`；绑定名取列名中的 `<binding>`，
  缺省 `"o"`。多模式决策表不在本变更范围。
- CSV 解析器自研（RFC 4180 + 注释 + BOM），不引入 `f_csv`（仓库无此模块）。
- XLSX 只做"`f_excel` 读取结果 → 字符串/字面量"的映射，读完即丢 `CellValue`；`Formula(_, None)` 与
  `Error` 抛 `TABLE_INVALID`。
- 类型推断优先级：`CellValue` 变体 > 类型行 > 字段声明；冲突以字段声明为准并 WARN（Excel 常把 `3` 存成
  数字、把 `>=3` 存成文本，字段声明是唯一权威）。

### D10. 命中策略聚合：`fire` 的详细结果

`TableExecutor` 需要"哪些行命中、各自输出什么"，而 `doc/08` 的 `session.fire()` 只返回合并后的输出槽。
因此 `RuleSession` 额外提供 `fireDetailed(limit): FireResult`（`outputs` + `fired: Array<(ruleId, outputs)>`），
`fire()` 是它的薄封装。`TableExecutor` 用 `fireDetailed` 收集行级输出，再按 `HitPolicy` 聚合；
`Unique/Priority/Any` 的冲突判定在聚合阶段完成。

### D11. 初始化与依赖

- 新增依赖：`fountain::f_app`（`Initializer`）、`fountain::f_ticktock`（`JoinTask` 超时）。
  两者均不反向依赖 `f_rule`，无环。
- `RuleInitializer <: Initializer`：`name = "fountain::f_rule"`、`dependencies = ["fountain::f_egraph"]`，
  `static init()` 中 `InitializerCollection.register(RuleInitializer())`；`initialize()` 只做
  `RuleRuntime.ensureCompiler()`，不主动加载规则（规则由应用注入）。
- `RuleRuntime.initCompiler(compiler)`：应用必须"先 `f_jit` 注册类型、再 `f_egraph` 初始化、再 `f_rule`"，
  顺序写进 README；`RuleSet.build()` 前校验未登记类型。
- `f_rule/cjpm.toml` 保持 `include = ["src"]`、`output-type = "dynamic"`、`--dy-std`；
  新增两个路径依赖，不新增 `[target]` 段（与同仓库其他模块一致）。

### D12. 错误码收敛

以 `doc/01` §6 的 14 个码为基线，补足文档其他章节实际使用但未列入的：
`DUPLICATE_FACT`、`ILLEGAL_STATE`、`UNKNOWN_BINDING`、`SCRIPT_COMPILE`、`SCRIPT_BINDING_MISSING`、
`FANOUT_WITHOUT_JOIN`、`SAME_SPACE_FANOUT`、`EMPTY_FANOUT`、`REENTRANT_FIRE`、`ACTION_FAILED`、
`NO_CONTEXT`、`CLOSED`、`TABLE_MODE_CONFLICT`。共 27 个（见 engine-core spec）。全部为 `public enum`，`toString()` 输出
大写蛇形名，日志与决策表定位共用同一套字符串。

### D13. 测试与差分

- 单元/组件/网络/端到端测试与被测代码同目录，`*_test.cj`；用例编号写在测试类注释里（`R-05` 等），
  便于对账 `doc/09`。
- 差分基准 `NaiveMatcher` 放 `src/test/`，只做嵌套循环 + 逐条判定，语义透明；随机生成器
  `PropertyGen` 用固定种子（`Random(20261031)`）保证可复现，≥ 200 组，覆盖 1~5 模式、
  0~4 约束、等值/范围/In/IsNull 混合、0~200 事实、0~50 规则、插入后随机撤销 30%。
- `f_jit` vs 解释器差分：同一批源码在 `JitPreferred` 与 `Interpreted` 下逐条比对。
- 性能门禁写在 `src/Perf_test.cj`（`@Test` + 阈值断言），不建独立 bench 模块——避免把基准代码打进
  动态库；门禁值写入 `f_rule/doc/perf.md`。

### D14. 发布登记

`.modules` 的 `[include]` 增加 `f_rule`（放在 `f_excel` 之后，保持与现有发布顺序一致）；
`f_rule/README.md` 状态段更新；新增 `f_rule/CHANGELOG`。不改根 `cjpm.toml` 依赖列表与根 `src/`。

## Risks

| 编号 | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | `f_jit` 不支持 `Option`/`Any` 返回，动态事实表达式受限 | 高（已确认） | 动态事实脚本条件只能走解释器 | D7 能力性降级 + 构建期 WARN + 文档说明 |
| R2 | 范围索引性能不足 | 低 | 大表范围 join 慢 | 直接用 `ConcurrentSkipListMap`（O(log n)），B-02 门禁兜底 |
| R3 | `produced` 索引内存翻倍 | 中 | RSS 超标 | 只对参与 join 的事实记录；B-05 门禁 |
| R4 | 扇出缺汇合导致残留事件串到下一个 session | 高（上游已确认） | 静默错误结果 | 构建期 `FANOUT_WITHOUT_JOIN` + P-05b 回归用例 |
| R5 | `emit` 丢 session | 高（上游已确认） | 事实库串会话 | `RuleEnvelope` + spec R5 场景 |
| R6 | `f_jit` 进程级编译缓存键不含注册类型集合 | 中 | 不同类型串编译结果 | 生成源码含完全限定类型名（D7） |
| R7 | `f_jit` 全局 `callMtx` 串行 | 中 | 多会话并发吞吐受限 | 议程单线程；文档标注脚本条件不适用高并发；必要时降级解释器 |
| R8 | 规则数上万时 Flow 模式内存高 | 中 | 启动慢 | 文档明确 Flow 模式适用千级以内，更大规模用产生式模式 |
| R9 | 决策表 `factType` 缺失 | 中 | 构建期歧义 | D9 的 `TABLE_INVALID` + 自动推断单类型 |

## Testing strategy

| 层 | 范围 | 手段 |
|---|---|---|
| L1 | 单类契约 | 直接构造 + 断言 |
| L2 | 事实库、索引、令牌、议程 | 组合少量类 |
| L3 | 规则 → 网络匹配 | 与 `NaiveMatcher` 差分（≥200 组） |
| L4 | 决策表 → 规则集 → 引擎 | 端到端 |
| L5 | ResolveTask / JoinTask / 版本切换 | 真实 `f_egraph` Flow |
| L6 | 规模与内存 | `@Test` 门禁（B-01~B-07） |

提交门禁：`cjpm build` 通过、`cjpm test` 全绿、新增公开 API 有用例、涉及网络/议程的改动跑差分、
性能路径不退化超过 10%。

## Migration / rollout

1. M0 只改模块骨架与登记，`cjpm build` 必须空模块通过；此时不影响任何现有模块。
2. M1/M2 引入 `fact`/`condition`/`rete` 包，`RuleSet.build()` 先走 `NaiveMatcher`（可运行但慢），
   M2 完成后切到 Rete，`NaiveMatcher` 保留为差分基准（`RuleSet` 增加内部开关 `matcher = Naive|Rete`，仅测试使用）。
3. M3 引入 `RuleEngine`/`RuleSession`，M1 的内部 API 不对外。
4. M4~M6 纯新增，不改上游模块。
5. M7 只加门禁与文档，版本号沿用模块当前 `1.3.17`，首次发布在 M7 收尾后由 `fountain-tag` 流程处理。
