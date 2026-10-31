# `fountain::f_rule` 规则引擎

建立在 [`f_egraph`](../f_egraph/README.md) 与 [`f_jit`](../f_jit/README.md) 之上的规则引擎：事实库、Rete 网络、议程与决策表。

## 能力

| 能力 | 说明 |
|---|---|
| 双形态事实 | 强类型业务类（`@JitBind` + `FactSchema`）与动态字典（`DynamicFact`）并存 |
| 多事实库 | 每条规则可指定独立 `FactSpace`，也可多条规则共享；Rete 按空间分片，跨空间不可 join |
| 条件求值 | 内置算子（`Eq`/`Gt`/`In`/`IsNull`/…）+ f_jit 表达式 + 内置解释器降级 |
| Rete 网络 | alpha/beta 节点共享、等值/范围索引、令牌父链共享、增量插入与撤销 |
| 议程 | 6 种冲突消解策略 + 组合，3 种 `FireMode`，循环检测 |
| 决策表 | 构建 API、CSV、XLSX 三载体，7 种命中策略 |
| 决策流 | 一条规则一个 `f_egraph.Flow`；`ResolveTask` 扇出，`JoinTask` 汇合 |
| 共享事实库 | 按规则集 + 会话隔离，流程与产生式模式共用 |

## 快速开始

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

## 文档

完整技术文档见 [`doc/`](doc/README.md)：

| 文档 | 内容 |
|---|---|
| [doc/01-architecture.md](doc/01-architecture.md) | 分层架构、包结构、并发模型、错误码 |
| [doc/02-fact-model.md](doc/02-fact-model.md) | 事实模型与会话隔离 |
| [doc/03-condition-expression.md](doc/03-condition-expression.md) | 算子、条件树、f_jit 表达式 |
| [doc/04-rete-network.md](doc/04-rete-network.md) | Rete 网络与增量算法 |
| [doc/05-agenda-conflict-resolution.md](doc/05-agenda-conflict-resolution.md) | 议程与冲突消解 |
| [doc/06-flow-orchestration.md](doc/06-flow-orchestration.md) | 规则流、`ResolveTask`、`JoinTask` |
| [doc/07-decision-table.md](doc/07-decision-table.md) | 决策表三载体 |
| [doc/08-api.md](doc/08-api.md) | 对外 API 与示例 |
| [doc/09-testing.md](doc/09-testing.md) | 测试策略与用例矩阵 |
| [doc/10-roadmap.md](doc/10-roadmap.md) | 里程碑与验收标准 |

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


## 构建

```bash
cd f_rule
cjpm build
cjpm test
```

M0 实测（aarch64 Linux / 7 核 / `cjc 1.3.0-alpha`）：冷构建含全部路径依赖约 **3m54s**，
增量构建约 **3s**，`cjpm test` 增量约 **5s**。

## 状态

**M0 骨架完成，尚不可用于生产**：`src/` 目前只有包骨架、错误码/异常、`RuleRuntime` 与
`RuleInitializer`；事实模型、条件、Rete、议程、决策流、决策表按 [doc/10-roadmap.md](doc/10-roadmap.md)
的 M1~M7 推进。快速开始示例是目标形态，M3 之后才可运行。

## 许可

Apache-2.0
