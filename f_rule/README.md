# `fountain::f_rule` 规则引擎

建立在 [`f_egraph`](../f_egraph/README.md) 与 [`f_jit`](../f_jit/README.md) 之上的规则引擎：事实库、Rete 网络、议程与决策表。

## 能力

| 能力 | 说明 |
|---|---|
| 双形态事实 | 强类型业务类（`@JitBind` + `FactSchema`）与动态字典（`DynamicFact`）并存 |
| 多事实库 | 每条规则可指定独立 `FactSpace`，也可多条规则共享；Rete 按空间分片，跨空间不可 join |
| 条件求值 | 15 个内置算子 + `f_jit` 表达式 + 内置解释器（`ExpressionMode.Interpreted` 可强制） |
| Rete 网络 | alpha/beta 节点共享、等值/范围索引、令牌父链共享、增量插入与撤销 |
| 议程 | 6 种冲突消解策略 + 组合，3 种 `FireMode`，互斥组 `activationGroup`，循环检测 |
| 决策表 | 构建 API / CSV / XLSX 三载体，7 种命中策略；可聚合执行，也可编译进议程 |
| 决策流 | 一条规则一个 `f_egraph.Flow`；`ResolveTask` 扇出，`JoinTask` 汇合 |
| 共享事实库 | 按 `(space, session)` 隔离，流程与产生式模式共用 |

## 三种典型用法

### 1. 产生式模式

规则落到 Rete 网络，事实插入后增量匹配，议程按冲突消解顺序执行。

```cangjie
import fountain::f_rule.*

@JitBind
public class Order {
    public var id: String
    public var amount: Int64
    public var level: Int64
    public init(id: String, amount: Int64, level: Int64) {
        this.id = id
        this.amount = amount
        this.level = level
    }
}

main() {
    let schema = FactSchema<Order>("Order")
        .field("amount", FieldType.Number, { o => o.amount })
        .field("level", FieldType.Number, { o => o.level })

    let vip = Rule.builder("R1")
        .salience(100)
        .facts("orders")
        .addPattern(Pattern("Order", "o")
            .constrain("level", Operator.Ge, 3)
            .constrain("amount", Operator.Gt, 200))
        .then { ctx => ctx.set("discount", 0.85) }
        .build()

    let ruleSet = RuleSetBuilder("pricing")
        .version("v1")
        .factSpace("orders")
        .registerFact("orders", schema)
        .rule(vip)
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    session.assert("orders", TypedFact(Order("1001", 500, 3), schema))
    println(session.fire().get("discount").getOrThrow())     // 0.85
}
```

### 2. 决策表：聚合执行

整表求值 + `HitPolicy` 聚合，输出 `TableResult`（含行级 `RowTrace`），不进议程。

```cangjie
let table = CsvTableParser.parseFile(Path("./rules/pricing.csv"))

let ruleSet = RuleSetBuilder(table.id)
    .version(table.version)
    .factSpace("orders")
    .registerFact("orders", schema)
    .build()

let engine = RuleEngine(ruleSet)
let session = engine.session("order-1001")
session.assert("orders", TypedFact(Order("1001", 500, 3), schema))

let result = engine.executeTable(table, session)
for (hit in result.hits) {
    println("${hit.ruleId} -> ${hit.outputs}")
}
```

### 3. 决策表：编译进议程

表按行编译成规则，与代码规则在同一条议程上排序。适合「表给人的是一张决策矩阵，但要和手写规则互斥或分级」。

```cangjie
let agendaTable = XlsxTableParser.parse(Path("./rules/pricing.xlsx"), "pricing")

let ruleSet = RuleSetBuilder("pricing")
    .version("v1")
    .factSpace("orders")
    .registerFact("orders", schema)
    .table(agendaTable)          // 表规则
    .rule(manualOverride)        // 代码规则，可与表规则同 activationGroup 互斥
    .build()
```

同一张表**不能**两条路都走：装配过的表再 `executeTable` 会抛 `TABLE_MODE_CONFLICT`，反之亦然。这是实例级互斥，不同实例不受限。

### 4. 决策流

需要显式编排顺序或并行分支时，给每条规则一个 `f_egraph.Flow`。

```cangjie
let flow = RuleSetFlow.build(engine)
    .start("order.created")
    .fanout("order.created", [
        ("order.vip.check", "pricing/R1"),
        ("order.bulk.check", "pricing/R2")     // 两条分支必须属于不同 factSpace
    ])
    .join(["order.vip.done", "order.bulk.done"], "order.priced")
    .end()
    .flow
```

## 约束

| 约束 | 原因 |
|---|---|
| 扇出分支必须 `JoinTask` 汇合 | `f_egraph` 的 `dispatch` 遇 `EndExecutor` 立即返回且不清队列，残留事件会在下次 `start()` 被消费。构建期 BFS 拦截，违反抛 `FANOUT_WITHOUT_JOIN` |
| 同 `factSpace` 的分支不能扇出 | 并发改写同一批事实时执行顺序由队列决定，不可控；构建期抛 `SAME_SPACE_FANOUT` |
| 跨空间不能 join | 撤销语义依赖两个库的生命周期；需要跨库数据用 `ActionContext.copyTo` 显式物化 |
| 进入网络的事实不可变 | 索引与事实内容必须一致；修改走 `FactBase.update()`（内部 retract + assert） |
| 同一 `DecisionTable` 实例只用一条路径 | 装配 + 聚合会重复触发；抛 `TABLE_MODE_CONFLICT` |
| 流式表不可并发遍历 | 多个 `rowIterator()` 共享底层 ZIP 流；串行多次迭代安全 |

## 文档

完整技术文档见 [`doc/`](doc/README.md)：

| 文档 | 内容 |
|---|---|
| [doc/01-architecture.md](doc/01-architecture.md) | 分层架构、包依赖方向、核心数据流、错误码 |
| [doc/02-fact-model.md](doc/02-fact-model.md) | 事实模型、`FactSpace` 与二维会话隔离 |
| [doc/03-condition-expression.md](doc/03-condition-expression.md) | 算子、条件树、`f_jit` 表达式与解释器 |
| [doc/04-rete-network.md](doc/04-rete-network.md) | Rete 网络、节点共享、索引、增量与撤销 |
| [doc/05-agenda-conflict-resolution.md](doc/05-agenda-conflict-resolution.md) | 议程、冲突消解、`activationGroup`、循环控制 |
| [doc/06-flow-orchestration.md](doc/06-flow-orchestration.md) | 规则流、`ResolveTask`、`JoinTask` |
| [doc/07-decision-table.md](doc/07-decision-table.md) | 决策表三载体、7 种命中策略、两条执行路径的差异 |
| [doc/08-api.md](doc/08-api.md) | 对外 API 与完整示例 |
| [doc/09-testing.md](doc/09-testing.md) | 测试矩阵（含 I-01~I-06）与性能门禁 |
| [doc/10-roadmap.md](doc/10-roadmap.md) | 里程碑与验收标准 |
| [doc/11-assembly.md](doc/11-assembly.md) | 装配层设计：`table()` / `executeTable()` 与包依赖解法 |
| [doc/perf.md](doc/perf.md) | B-01~B-07 门禁实测值与测量方法 |

## 依赖

| 模块 | 用途 |
|---|---|
| `fountain::f_egraph` | 流程、事件、任务 |
| `fountain::f_jit` | 表达式编译与脚本规则体 |
| `fountain::f_excel` | XLSX 决策表读取 |
| `fountain::f_regex` | `Matches` 算子 |
| `fountain::f_app` | `Initializer` 注册（`RuleInitializer`） |
| `fountain::f_ticktock` | `JoinTask` 超时定时器 |
| `fountain::f_base` / `f_collection` / `f_concurrent` / `f_log` / `f_util` | 基础设施 |

### 初始化顺序

`f_jit` 的编译缓存是进程级的，`f_egraph` 与 `f_rule` 必须共用同一个 `Compiler`，否则脚本规则体会
在两边各编译一份、且类型注册互不可见。应用按下列顺序初始化：

```cangjie
let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
compiler.registerType<Order>()                 // 1. f_jit：登记参与脚本的类型
RuleRuntime.initCompiler(compiler)             // 2. f_rule：注入共享编译器
// 3. f_egraph / f_rule 由 f_app.InitializerCollection 启动
```

未调用 `RuleRuntime.initCompiler` 时，首次使用会惰性创建默认 `Compiler` 并打印一次 `WARN`——
默认实例看不到应用注册的类型，脚本条件会在 `RuleSet.build()` 抛 `SCRIPT_COMPILE`。

## 构建与测试

```bash
cd f_rule
cjpm build
cjpm test

# 只跑功能回归，跳过性能门禁与规模用例
cjpm test --exclude-tags=perf

# 只跑性能门禁（B-01~B-07）
cjpm test --include-tags=perf --no-capture-output
```

| 项 | 实测（aarch64 Linux / 7 核 / `cjc 1.3.0-alpha`） |
|---|---|
| 冷构建（含全部路径依赖） | 约 4 分钟 |
| 增量构建 | 约 3 秒 |
| `cjpm test` 全量（418 用例，含性能门禁） | 约 2m45s |
| `cjpm test --exclude-tags=perf` | 约 1m20s |

## 状态

**可用**：M0~M7 全部完成，`cjpm test` 418/418 通过，性能门禁 B-01~B-07 全部达标（见 [doc/perf.md](doc/perf.md)）。

已知边界：

- **决策表在议程路径有三项 `HitPolicy` 降级**（`Unique` 运行期不报错、`Priority` 降级行序、`Any` 不校验输出一致、`OutputOrder` 按行序）。需要完整语义用 `executeTable`，详见 [doc/07](doc/07-decision-table.md) §2.1。
- **B-02 的余量约 42%**（1162 ms / 2000 ms），后续改动涉及插入路径必须重跑门禁。
- **`cjlint` 在当前 SDK 发行版不可用**：`$CANGJIE_HOME/modules` 及其平台子目录都无法被定位，各路径均报 `Can not find modules`。
- **`cjfmt` 默认配置与项目 License 头惯例冲突**：全仓库（含 `f_egraph` 等既有模块）统一写 `*/`，`cjfmt` 期望 ` */`。未为通过检查而批量改写。

## 许可

Apache-2.0
