# `fountain::f_rule` 规则引擎

建立在 [`f_egraph`](../f_egraph/README.md) 与 [`f_jit`](../f_jit/README.md) 之上的规则引擎：事实库、Rete 网络、议程与决策表。

## 能力

| 能力 | 说明 |
|---|---|
| 双形态事实 | 强类型业务类（`@JitBind` + `FactSchema`）与动态字典（`DynamicFact`）并存 |
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
        .when(Pattern("Order", "o")
            .where("level", Operator.Ge, 3)
            .where("amount", Operator.Gt, 200))
        .then { ctx => ctx.set("discount", 0.85) }
        .build()

    let ruleSet = RuleSet.builder("pricing")
        .version("v1")
        .registerFact(schema)
        .rule(vip)
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    session.assert(TypedFact(Order("1001", 500, 3), schema))
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
| `fountain::f_base` / `f_collection` / `f_concurrent` / `f_log` / `f_util` | 基础设施 |

## 构建

```bash
cd f_rule
cjpm build
cjpm test
```

## 状态

**设计阶段**：`src/` 尚未实现，技术文档已完成。实施计划见 [doc/10-roadmap.md](doc/10-roadmap.md)。

## 许可

Apache-2.0
