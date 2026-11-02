# `fountain::f_rule` 规则引擎

建立在 [`f_egraph`](../f_egraph/README.md) 与 [`f_jit`](../f_jit/README.md) 之上的规则引擎：事实库、Rete 网络、议程、决策表与决策流。声明式规则、决策表与 `f_jit` 脚本共用同一套事实模型与同一个 `Compiler`。

## 特性

| 能力 | 说明 |
|---|---|
| 双形态事实 | `TypedFact<T>` + `FactSchema<T>`（强类型业务类，字段可被脚本读取）与 `DynamicFact`（动态字典，表达式走内置解释器）并存 |
| 多事实库 | 一个规则集可声明多个 `FactSpace`；规则归属一个空间，Rete 按空间分片，跨空间不可 join |
| 条件求值 | 15 个算子 + 三值逻辑；条件树 `And`/`Or`/`Not`/`Leaf`/`Join`/`Script`；`ExpressionMode.Interpreted` 可强制解释器 |
| Rete 网络 | alpha/beta 按签名共享、等值/范围索引、令牌父链共享 + 引用计数、增量插入与撤销 |
| 议程 | 6 种冲突消解策略 + `CompositeResolver`、3 种 `FireMode`、`activationGroup` 互斥组、循环检测 |
| 决策表 | 构建 API / CSV / XLSX 三载体，7 种 `HitPolicy`；可聚合执行（`executeTable`），也可编译进议程（`RuleSetBuilder.table`） |
| 决策流 | 一条规则一个 `f_egraph.Flow`；`ResolveTask` 扇出、`JoinTask` 汇合（可超时） |
| 引擎门面 | `RuleEngine` / `RuleSession`；`fire` / `fireDetailed`；表执行器按 `(id, version)` 缓存 |

## 快速开始

```cangjie
import fountain::f_rule.*
import fountain::f_rule.fact.FieldType

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

func orderSchema(): FactSchema<Order> {
    FactSchema<Order>("Order")
        .field("id", FieldType.Text) { o => o.id }
        .field("amount", FieldType.Number) { o => o.amount }
        .field("level", FieldType.Number) { o => o.level }
}

main() {
    let vip = Rule.builder("R1")
        .salience(100)
        .facts("orders")                                  // 规则归属的事实库空间
        .addPattern(Pattern("Order", "o")                 // typeTag + 绑定名
            .constrain("level", Operator.Ge, 3)
            .constrain("amount", Operator.Gt, 200))
        .then({ ctx => ctx.set("discount", 0.85) })       // 输出槽
        .build()

    let ruleSet = RuleSetBuilder("pricing")
        .version("v1")
        .factSpace("orders")
        .registerFact("orders", orderSchema())
        .rule(vip)
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    let _ = session.assert("orders", TypedFact(Order("1001", 500, 3), orderSchema()))

    let outputs = session.fire()
    let discount = outputs.get("discount").getOrThrow() as Float64
    println("discount = ${discount}")                     // 0.85
    engine.close()
}
```

包根 `fountain::f_rule` 只重导出常用类型，其余按子包显式导入：

| 需要用到 | 导入 |
|---|---|
| `FieldType`、`FactBase`、`FactBaseView`、`FactSpaceRegistry`、`TypeTag` | `fountain::f_rule.fact` |
| `Constraint`、`Operand`、`JoinConstraint`、`ConditionExpr`、`ExpressionMode`、`Truth` | `fountain::f_rule.condition` |
| `ActionContext`、`ConflictResolver`、`RuleSetStatus` | `fountain::f_rule.rule` |
| `Resolvers` 与 6 个冲突消解策略、`CycleDetector` | `fountain::f_rule.agenda` |
| `EngineOptions` | `fountain::f_rule.engine` |
| `RuleException`、`RuleErrorCode` | `fountain::f_rule.exception` |
| `TableExecutor`、`TableCompiler`、`HitAggregator` | `fountain::f_rule.table` |

## 核心概念

| 概念 | 类型 | 说明 |
|---|---|---|
| 事实 | `Fact` / `TypedFact<T>` / `DynamicFact` | 可字段寻址的数据单元；进入网络后不可变 |
| 类型描述 | `FactSchema<T>` / `FactSpace` | 字段名 + `FieldType` + getter；`typeTag` 是规则引用类型的键 |
| 事实库空间 | `FactSpace` | 命名空间；相同 id 共享事实与网络分片，缺省为 `default` |
| 事实视图 | `FactBaseView` | `(space, session)` 级容器：`assert` / `retract` / `update` / `scan` / `copyTo` / `fork` |
| 模式 | `Pattern` | 类型 + 绑定名 + 约束集 |
| 约束 | `Constraint` / `JoinConstraint` | 单事实判定 / 跨模式字段比较 |
| 规则 | `Rule` | 模式 + join + 脚本条件 + 动作 + 空间 + `salience` + `activationGroup` |
| 规则集 | `RuleSet` | 规则 + 空间注册表 + 版本 + 求值模式 + 冲突消解策略；构建后冻结 |
| 激活 | `Activation` | 一条规则 + 一组绑定；`seq` 单调分配，只用于全序兜底 |
| 议程 | `Agenda` | 会话级优先队列，跨空间统一排序 |
| 会话 | `RuleSession` | 事实 + Rete 运行态 + 议程 |

## 四种典型用法

### 1. 产生式模式

规则落到 Rete 网络，事实插入后增量匹配，议程按冲突消解顺序执行。多模式规则用 `JoinConstraint` 连接：

```cangjie
let crossSell = Rule.builder("R2")
    .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 500))
    .addPattern(Pattern("User", "u").constrain("vip", Operator.Eq, true))
    .join(JoinConstraint("o", "userId", Operator.Eq, "u", "id"))
    .then({ ctx =>
        let order = ctx.fact("o").getOrThrow()
        ctx.set("userId", order.get("userId").getOrThrow())
    })
    .build()
```

附加脚本条件用 `.script(...)`：源码在 `RuleSet.build()` 时编译，形参必须是模式的绑定名。

```cangjie
let risky = Rule.builder("R3")
    .addPattern(Pattern("Order", "o"))
    .script("{ o: Order => o.amount * 2 > 1000 }")
    .then({ ctx => ctx.set("flag", true) })
    .build()
```

### 2. 决策表：聚合执行

整表求值 + `HitPolicy` 聚合，输出 `TableResult`（含行级 `RowTrace`），不进议程。适合"给定一批事实，输出被规则表唯一确定的结果"。

```cangjie
import fountain::f_rule.*
import std.fs.Path

main() {
    let table = CsvTableParser.parseFile(Path("./rules/pricing.csv"))

    let ruleSet = RuleSetBuilder(table.id)              // 聚合路径不装配表，只需空间与类型
        .version(table.version)
        .factSpace(table.factSpace)
        .registerFact(table.factSpace, orderSchema())
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    let _ = session.assert(table.factSpace, TypedFact(Order("1001", 500, 3), orderSchema()))

    let result = engine.executeTable(table, session, trace: true)
    for (i in 0..result.hits.size) {
        let discount = result.outputs[i].get("discount").getOrThrow() as Float64
        println("${result.hits[i].ruleId}: discount=${discount}")
    }
    for (row in result.trace) {                          // 为什么某行没命中
        println("${row.ruleId}: matched=${row.matched}")
    }
}
```

`TableResult.hits` 与 `TableResult.outputs` 按索引一一对应；`trace` 仅在 `trace: true` 时非空。

### 3. 决策表：编译进议程

表按行编译成规则，与代码规则在同一条议程上排序。适合"表给人的是一张决策矩阵，但要和手写规则互斥或分级"。

```cangjie
import fountain::f_rule.*
import std.fs.Path

main() {
    let pricing = XlsxTableParser.parse(Path("./rules/pricing.xlsx"), "pricing")

    let ruleSet = RuleSetBuilder("pricing")
        .version("v1")
        .factSpace("orders")
        .registerFact("orders", orderSchema())
        .table(pricing)                   // 表规则：行 id 即规则 id
        .rule(manualOverride)             // 手写规则（略），可与表规则同 activationGroup 互斥
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    let _ = session.assert("orders", TypedFact(Order("1001", 500, 3), orderSchema()))
    let _ = session.fire()
}
```

同一张表**不能**两条路都走：装配过的表再 `executeTable` 会抛 `TABLE_MODE_CONFLICT`，反之亦然。这是实例级互斥，不同实例不受限。

### 4. 决策流

需要显式编排顺序或并行分支时，给每条规则一个 `f_egraph.Flow`：

```cangjie
import fountain::f_rule.*
import fountain::f_rule.fact.Fact

func intoSpace(env: RuleEnvelope, space: String): Array<(String, Fact)> {
    match (env.payload) {
        case fact: Fact => [(space, fact)]
        case _ => Array<(String, Fact)>()
    }
}

main() {
    // engine 见上文「产生式模式」；两条分支规则分别归属 orders / users 空间
    let builder = RuleSetFlow.build(engine)
        .start("order.created")
        .fanout("order.created", [
            ("order.vip.check", "pricing/R1"),
            ("order.bulk.check", "pricing/R2")     // 两条分支必须属于不同 factSpace
        ])

    // 分支处理器挂在同一底层流程上：RuleTask 负责 assert 事实并 fire 议程
    builder.flow.registerTask(RuleTask(engine,
        name: "order.vip.check",
        acceptable: ["order.vip.check"],
        output: "order.vip.done",
        factory: { env => intoSpace(env, "orders") }))

    builder.flow.registerTask(RuleTask(engine,
        name: "order.bulk.check",
        acceptable: ["order.bulk.check"],
        output: "order.bulk.done",
        factory: { env => intoSpace(env, "users") }))

    let flow = builder
        .join(["order.vip.done", "order.bulk.done"], "order.priced")
        .end()
        .flow

    let _ = flow.start(TypedFact(Order("1001", 500, 3), orderSchema()))
}
```

`RuleSetFlow` 只组装 `ResolveTask` / `JoinTask` 这两类编排任务；分支里"哪条规则、读哪个空间"由挂到 `flow` 上的 `RuleTask` 决定。`JoinTask` 配置 `timeout` 时依赖 `f_ticktock`，未初始化会在构造期记一条 WARN 并退化为不超时。

## 决策表文件格式

### CSV

```csv
# f_rule decision table v1
# id: pricing
# name: 订单折扣
# version: v1
# factSpace: orders
# factType: Order
# hitPolicy: First
# salience: 100
id,name,when.order.level,when.order.amount,then.discount,then.event
R1,VIP 大额,>=3,>200,0.85,order.discounted
R2,普通大额,>=1,>500,0.90,order.discounted
R3,兜底,,,1.0,order.discounted
```

- `# key: value` 是表属性（键大小写不敏感），`id` 必需，其余 `#` 行是注释；文件必须是 UTF-8（可带 BOM），引号与转义按 RFC 4180。
- 第一行非注释行是表头，其后每行一条规则；行列数必须与表头一致，错误消息带物理行号。
- `id` 列为空时自动编号 `R1`、`R2`…。
- 支持的属性：`id`、`name`、`version`（缺省 `v1`）、`factSpace`（缺省 `default`）、`factType`、`hitPolicy`（缺省 `First`）、`salience`、`outputOrder`（逗号分隔）。

### XLSX

- sheet 名即表 id；第 1 行表头，第 2 行可选类型行（非空单元格必须是 `number`/`text`/`bool`/`time`/`list` 之一，否则该行按数据行处理），数据从第 3 行（无类型行时从第 2 行）开始。
- `_meta` sheet 用两列 key/value 承载上面那组表属性。
- `_meta` 之外的每个 sheet 是一张表；整表读取展开合并单元格，流式读取不展开并在流尾记 WARN。
- `Error` 单元格、无缓存值的 `Formula` 单元格抛 `TABLE_INVALID`（带缓存值的公式按缓存值处理）。
- 大表用 `XlsxTableParser.stream(path)`：`DecisionTable.rows` 为空，`rowIterator()` 每次现读，内存与行数无关。

### 表头与单元格

| 列名 | 含义 |
|---|---|
| `id` / `name` | 行 id（规则 id）与行名 |
| `salience` | 行优先级（整数） |
| `when.<field>` / `when.<binding>.<field>` | 条件列；单模式表可省略 binding（缺省 `o`），同一张表所有条件列必须同一 binding |
| `then.<输出名>` | 输出槽名 |
| `expr.<列名>` | 裸布尔表达式（`f_jit` 或解释器），按同一 binding 包装 |

条件单元格（算子大小写不敏感）：

| 写法 | 算子 |
|---|---|
| 空 / `-` | 不约束 |
| `null` / `not null` | `IsNull` / `NotNull` |
| `>=x` `<=x` `!=x` `=x` `==x` `>x` `<x` | `Ge` `Le` `Ne` `Eq` `Eq` `Gt` `Lt` |
| `in [a, b]` / `not in [a, b]` | `In` / `NotIn` |
| `between [a, b]` | `Between`（恰好两个边界值） |
| `contains x` / `startswith x` / `endswith x` / `matches x` | `Contains` / `StartsWith` / `EndsWith` / `Matches` |
| 其它裸值 | `Eq`，按字段声明的 `FieldType` 解析 |

输出单元格：`${binding.field}` 取命中事实字段，`${binding}` 取整个事实，其它按字面量推断（数字 / 布尔 / 时间 / 文本）。引用的绑定必须是该行条件里出现过的绑定，否则抛 `UNKNOWN_BINDING`。

### 命中策略

| `HitPolicy` | 聚合路径（`executeTable`） | 议程路径（`table()`） |
|---|---|---|
| `Unique` | 零命中 `TABLE_NO_MATCH`、多命中 `TABLE_MULTI_MATCH` | 构建期检查重复行；运行期多命中只执行一条，不报错 |
| `First` | 按行序取第一行 | 同组互斥 + 行序 `salience` |
| `Priority` | 按 `outputOrder` 取最小 | 降级为行序 |
| `Any` | 多命中要求输出一致 | 不校验输出一致性 |
| `Collect` | 收集全部命中，按行序 | 全部执行 |
| `RuleOrder` | 收集全部，按 `salience` 降序 | 全部执行 |
| `OutputOrder` | 收集全部，按输出值升序 | 降级为行序 |

## API 速查

### 事实

```cangjie
public enum FieldType { Scalar, Number, Text, `Bool`, Time, List, `Any` }

public interface Fact {
    prop typeTag: String
    func get(field: String): ?Any
    func has(field: String): Bool
}

public class FactSchema<T> {
    public init(typeTag: String)
    public func field(name: String, getter: (T) -> Any): FactSchema<T>
    public func field(name: String, fieldType: FieldType, getter: (T) -> Any): FactSchema<T>
    public func names(): Array<String>
    public func has(name: String): Bool
    public func fieldType(name: String): FieldType
}

public class TypedFact<T> <: Fact {
    public init(value: T, schema: FactSchema<T>)
    public let value: T
    public prop schema: FactSchema<T>
}

public class DynamicFact <: Fact {
    public init(typeTag: String)
    public init(typeTag: String, values: HashMap<String, Any>)
    public func get(field: String): ?Any
    public func set(field: String, value: Any): Unit
    public func remove(field: String): Unit
    public func freeze(): Unit
}

public class FactBaseView {
    public prop space: String
    public prop session: String
    public func assert(fact: Fact): FactHandle
    public func assertCopy(fact: Fact): FactHandle
    public func retract(handle: FactHandle): Bool
    public func update(handle: FactHandle, fact: Fact): Bool
    public func get(handle: FactHandle): ?Fact
    public func scan(typeTag: String): Array<FactHandle>
    public func size(): Int64
    public func copyTo(target: FactBaseView, fact: Fact): FactHandle
    public func fork(childSession: String, level!: IsolationLevel = IsolationLevel.Isolated): FactBaseView
    public func commitToParent(): Unit
}
```

`DynamicFact` 的字段值只接受 `String / Int64 / Float64 / Bool / DateTime / Decimal / Array<Any>`（及只读集合形态），其它类型在写入时抛 `TYPE_MISMATCH`；插入事实库时自动冻结。

### 条件

```cangjie
public enum Operator {
    Eq, Ne, Gt, Ge, Lt, Le, Contains, StartsWith, EndsWith,
    In, NotIn, IsNull, NotNull, Matches, Between
}

public class Pattern {
    public init(typeTag: String, binding: String, space!: String = "")
    public func constrain(field: String, op: Operator, value: Any): Pattern
    public func constrainField(field: String, op: Operator, rightField: String): Pattern
    public func constrainNot(field: String, op: Operator, value: Any): Pattern
    public func addConstraint(constraint: Constraint): Pattern
    public static func any(typeTag: String, binding: String): Pattern
}

public class JoinConstraint {
    public init(leftBinding: String, leftField: String, op: Operator,
        rightBinding: String, rightField: String)
}

public enum ConditionExpr {
    And(Array<ConditionExpr>), Or(Array<ConditionExpr>), Not(ConditionExpr),
    Leaf(Constraint), Join(JoinConstraint), Script(JitExpression)
}

public enum ExpressionMode { JitPreferred, Interpreted }
```

条件树经 `RuleBuilder.condition(typeTag, expr)` 进入规则，在 `RuleSet.build()` 时转成 DNF 后展开：每个合取项一条规则（`Or` 自然拆成多条，`And(Or(A, B), C)` 按分配律展开），多条时规则 id 追加 `#1`、`#2`，单条规则最多展开 64 条。树深上限 32；`Not` 可以包裹叶子、`And`、`Or`（否定下推），但不能包裹 `Join` 或 `Script`。

### 规则集

```cangjie
public class RuleSetBuilder {
    public init(id: String)
    public func version(version: String): RuleSetBuilder
    public func factSpace(id: String): RuleSetBuilder
    public func registerFact<T>(schema: FactSchema<T>): RuleSetBuilder
    public func registerFact<T>(space: String, schema: FactSchema<T>): RuleSetBuilder
    public func registerDynamicType(typeTag: String, fields: Array<String>): RuleSetBuilder
    public func registerDynamicType(space: String, typeTag: String, fields: Array<String>): RuleSetBuilder
    public func rule(rule: Rule): RuleSetBuilder
    public func rules(rules: Array<Rule>): RuleSetBuilder
    public func table(source: TableSource): RuleSetBuilder
    public func expressionMode(mode: ExpressionMode): RuleSetBuilder
    public func conflictResolver(resolver: ConflictResolver): RuleSetBuilder
    public func build(): RuleSet
    public func buildOrInvalid(): RuleSet
    public func lastError(): ?RuleException
}

public class Rule {
    public static func builder(id: String): RuleBuilder
    public let id: String
    public let salience: Int64
    public let factSpace: String
    public let activationGroup: ?String
    public let patterns: Array<Pattern>
    public let joins: Array<JoinConstraint>
    public let scripts: Array<String>
}

public class RuleBuilder {
    public func salience(value: Int64): RuleBuilder
    public func facts(space: String): RuleBuilder
    public func activationGroup(name: String): RuleBuilder
    public func addPattern(pattern: Pattern): RuleBuilder
    public func condition(typeTag: String, expr: ConditionExpr): RuleBuilder
    public func join(constraint: JoinConstraint): RuleBuilder
    public func script(source: String): RuleBuilder
    public func then(action: (ActionContext) -> Unit): RuleBuilder
    public func thenScript(source: String): RuleBuilder
    public func build(): Rule
}

public class RuleSet {
    public let id: String
    public let version: String
    public let rules: Array<Rule>
    public prop status: RuleSetStatus
    public prop closed: Bool
    public func isValid(): Bool
    public func factSpaces(): Array<FactSpace>
    public func enableCycleDetection(window!: Int64 = 10000): Unit
    public func configureExpressionTimeout(value: Duration): Unit
    public func ruleFailureCount(ruleId: String): Int64
    public func ruleDisabled(ruleId: String): Bool
    public func lastFailureKind(ruleId: String): ?EvalFailureKind
    public func close(): Unit
}
```

`build()` 失败即抛异常；`buildOrInvalid()` 把失败留在 `RuleSet.status`（`Invalid`），供诊断与测试使用。`RuleBuilder` 的 `addPattern` / `script` 对应文档里的 `when` / `where`——两个词是仓颉关键字，只能改名。

### 引擎与会话

```cangjie
public class RuleEngine {
    public init(ruleSet: RuleSet)
    public init(ruleSet: RuleSet, options: EngineOptions)
    public prop ruleSet: RuleSet
    public prop closed: Bool
    public func session(id: String): RuleSession
    public func release(id: String): Bool
    public func executeTable(table: DecisionTable, session: RuleSession, trace!: Bool = false): TableResult
    public func close(): Unit
}

public class EngineOptions {
    public init(expressionTimeout!: Duration = Duration.millisecond * 50)
    public var expressionTimeout: Duration
}

public class RuleSession {
    public prop id: String
    public prop facts: FactBaseView
    public func factsOf(space: String): FactBaseView
    public prop agenda: Agenda
    public func assert(fact: Fact): FactHandle
    public func assert(space: String, fact: Fact): FactHandle
    public func retract(handle: FactHandle): Unit
    public func update(handle: FactHandle, fact: Fact): Unit
    public func fire(limit!: Int64 = -1): HashMap<String, Any>
    public func fireDetailed(limit!: Int64 = -1): FireResult
}
```

同 id 的 `session(id)` 返回同一会话；`release(id)` 释放该会话的事实、令牌与议程。`close()` 级联关闭规则集，之后任何执行抛 `CLOSED`。

### 议程与冲突消解

```cangjie
public enum FireMode { Refract, NoLoop, Loop }

public class Agenda {
    public func fire(limit!: Int64 = -1): Int64
    public func setMode(mode: FireMode): Unit
    public func size(): Int64
    public func snapshot(): Array<Activation>
    public func clear(): Unit
    public func lastOutputs(): HashMap<String, Any>
    public func lastFired(): Array<FireRecord>
}

public interface ActionContext {
    prop factSpace: String
    func fact(binding: String): ?Fact
    func assert(fact: Fact): FactHandle
    func retract(handle: FactHandle): Unit
    func update(handle: FactHandle, fact: Fact): Unit
    func set(name: String, value: Any): Unit
    func get(name: String): ?Any
    func outputs(): HashMap<String, Any>
    func factIn(space: String, handle: FactHandle): ?Fact
    func copyTo(space: String, fact: Fact): FactHandle
}
```

- `Refract`（缺省）：执行后立即失效；`NoLoop`：同一规则同一绑定整次 `fire` 只执行一次；`Loop`：允许重复触发直到议程为空或 `limit`。
- 默认链 `salience ↓ → specificity ↓ → ruleOrder ↑ → seq ↑`，再由 `(factSpace, ruleId)` 兜底。可用 `Resolvers.salience()` / `specificity()` / `fifo()` / `lifo()` / `ruleOrder()` / `ruleId()` / `composite([...])` / `defaultChain()` 替换。
- `activationGroup` 同组激活只执行一条，其余在首个执行后失效；组名不参与激活相等键。
- `enableCycleDetection(window)` 开启后，同一激活指纹在窗口内超过阈值（100）抛 `CYCLE_LIMIT`。

### 决策表

```cangjie
public class DecisionTable <: TableSource {
    public static func builder(id: String): DecisionTableBuilder
    public let id: String
    public let name: String
    public let version: String
    public let factSpace: String
    public let factType: String
    public let hitPolicy: HitPolicy
    public let columns: Array<Column>
    public let rows: Array<TableRow>
    public let salience: Int64
    public let outputOrder: Array<String>
    public prop mode: TableMode
    public prop streaming: Bool
    public func rowIterator(): Iterator<TableRow>
    public func resolvedFactType(registry: FactSpaceRegistry): String
    public func compile(ruleSet: RuleSet): Array<Rule>
    public func compile(ruleSet: RuleSet, compiler: Compiler): Array<Rule>
}

public class DecisionTableBuilder {
    public func name(value: String): DecisionTableBuilder
    public func version(value: String): DecisionTableBuilder
    public func factSpace(space: String): DecisionTableBuilder
    public func factType(typeTag: String): DecisionTableBuilder
    public func hitPolicy(policy: HitPolicy): DecisionTableBuilder
    public func salience(value: Int64): DecisionTableBuilder
    public func outputOrder(names: Array<String>): DecisionTableBuilder
    public func column(header: String): DecisionTableBuilder
    public func whenColumn(path: String): DecisionTableBuilder
    public func thenColumn(name: String): DecisionTableBuilder
    public func exprColumn(name: String): DecisionTableBuilder
    public func row(values: Array<?String>): DecisionTableBuilder
    public func row(ruleId: String, values: Array<?String>): DecisionTableBuilder
    public func build(): DecisionTable
}

public enum HitPolicy { Unique, First, Priority, Any, Collect, RuleOrder, OutputOrder }

public class CsvTableParser {
    public static func parse(text: String): DecisionTable
    public static func parseFile(path: Path): DecisionTable
}

public class XlsxTableParser {
    public static func parse(path: Path): Array<DecisionTable>
    public static func parse(path: Path, sheet: String): DecisionTable
    public static func stream(path: Path): Iterator<DecisionTable>
}

public class TableResult {
    public let hits: Array<TableRow>
    public let outputs: Array<HashMap<String, Any>>
    public let trace: Array<RowTrace>
}
```

`factType` 未声明时按空间内唯一类型推断；空间注册了多个类型必须显式声明，否则抛 `TABLE_INVALID`。

### 流编排

```cangjie
public class RuleSetFlow {
    public static func build(engine: RuleEngine): RuleSetFlow
    public prop flow: ImmediateFlow
    public func start(name: String): RuleSetFlow
    public func fanout(event: String, branches: Array<(String, String)>): RuleSetFlow
    public func join(branches: Array<String>, output: String): RuleSetFlow
    public func end(): RuleSetFlow
}

public class RuleFlow {
    public static func build(ruleSetId: String, rule: Rule, version: String,
        acceptableEvent!: String = ""): RuleFlow
}

public class RuleTask {
    public init(engine: RuleEngine, name!: String, acceptable!: Array<String>, output!: String,
        factory!: ?FactFactory = None)
}

public class ResolveTask {
    public init(name!: String, acceptable!: Array<String>, producing!: Array<String>,
        plan!: (Event) -> Array<(String, Any)>)
}

public class JoinTask {
    public init(name!: String, branches!: Array<String>, output!: String,
        timeout!: ?Duration = None, timeoutEvent!: ?String = None,
        scheduler!: ?JoinTimeoutScheduler = None, timeoutSink!: ?(Event) -> Unit = None)
}

public class RuleEnvelope {
    public init(session!: String, ruleSetId!: String, payload!: Any, traceId!: String = "")
    public static func from(event: Event): RuleEnvelope
    public static func wrap(parent: Event, payload: Any): RuleEnvelope
    public func unwrap(): Any
}
```

`RuleEnvelope` 承载 session：`f_egraph` 的 `emit` 会为新事件生成随机 UUID，只有信封里的 `session` 能保证扇出后仍落在同一会话。

### 运行时

```cangjie
public class RuleRuntime {
    public static func initCompiler(compiler: Compiler): Unit
    public static func compiler(): Compiler
}
```

`RuleInitializer` 是 `f_app.Initializer` 实现（依赖 `fountain::f_egraph`），`initialize()` 只保证共享编译器可用；规则集由应用显式构建。

## 错误码

统一异常 `RuleException <: BaseException`，`code` 为 `RuleErrorCode`，`toString()` 是稳定的大写蛇形名（日志与告警依赖它）。

| 阶段 | 码 |
|---|---|
| 规则集装配 | `DUPLICATE_RULE`、`EMPTY_PATTERN`、`UNKNOWN_FACT_SPACE`、`EMPTY_FACT_SPACE_SET`、`CROSS_SPACE_JOIN`、`SAME_SPACE_FANOUT`、`DUPLICATE_TYPE`、`UNKNOWN_TYPE`、`UNKNOWN_FIELD`、`UNKNOWN_BINDING`、`TYPE_MISMATCH`、`NETWORK_FROZEN` |
| 事实 | `DUPLICATE_FACT`、`ILLEGAL_STATE` |
| 决策表 | `TABLE_INVALID`、`TABLE_NO_MATCH`、`TABLE_MULTI_MATCH`、`TABLE_MODE_CONFLICT` |
| 脚本 | `SCRIPT_COMPILE`、`SCRIPT_BINDING_MISSING` |
| 流程编排 | `FANOUT_WITHOUT_JOIN`、`EMPTY_FANOUT`、`NO_CONTEXT` |
| 议程运行时 | `CYCLE_LIMIT`、`REENTRANT_FIRE`、`ACTION_FAILED`、`CLOSED` |

编译期错误（规则定义、决策表、脚本）一律在构建阶段抛出，不留到运行期；运行期只保留事实类型不匹配、表达式运行时异常、动作异常、状态非法四类。

## 约束

| 约束 | 原因 |
|---|---|
| 进入网络的事实不可变 | 索引与事实内容必须一致；修改走 `RuleSession.update()`（内部等价 retract + assert 并传播到网络），直接改 `FactBaseView` 只改存储、不更新索引 |
| 一条规则的所有模式属于同一 `FactSpace` | 撤销语义依赖单个库的生命周期；跨库数据用 `ActionContext.copyTo` 显式物化 |
| 扇出分支必须由 `JoinTask` 汇合 | `f_egraph` 的 `dispatch` 遇 `EndExecutor` 立即返回且不清队列，残留事件会在下次 `start()` 被消费；构建期抛 `FANOUT_WITHOUT_JOIN` |
| 同 `factSpace` 的分支不能扇出 | 并发改写同一批事实时执行顺序由队列决定，不可控；构建期抛 `SAME_SPACE_FANOUT` |
| 同一 `DecisionTable` 实例只用一条路径 | 装配 + 聚合会重复触发；抛 `TABLE_MODE_CONFLICT` |
| 流式表不可并发遍历 | 多个 `rowIterator()` 共享底层 ZIP 流；串行多次迭代安全 |
| 规则集构建后冻结 | 空间与类型描述只读，运行期再注册抛 `NETWORK_FROZEN` |
| 版本切换以 `tag` 为单位 | 同一 `category` 下只允许一个活跃 `tag`，切换后调用 `removeExceptCurrentTag()` |

## 初始化顺序

`f_jit` 的编译缓存是进程级的，`f_egraph` 与 `f_rule` 必须共用同一个 `Compiler`，否则脚本规则体会在两边各编译一份、且类型注册互不可见：

```cangjie
import fountain::f_jit.*
import fountain::f_jit.macros.*
import fountain::f_rule.*
import fountain::f_rule.runtime.RuleRuntime

let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
compiler.registerType<Order>()          // 1. f_jit：登记参与脚本的宿主类型
RuleRuntime.initCompiler(compiler)      // 2. f_rule：注入共享编译器
// 3. f_egraph / f_rule 由 f_app.InitializerCollection 启动
```

未调用 `RuleRuntime.initCompiler` 时，首次使用会惰性创建默认 `Compiler` 并打印一次 WARN——默认实例看不到应用注册的类型，脚本条件会在 `RuleSet.build()` 抛 `SCRIPT_COMPILE`。

## 包结构

| 包 | 作用 |
|---|---|
| `fountain::f_rule` | 门面，`public import` 重导出常用声明 |
| `fountain::f_rule.runtime` | 共享 `Compiler`（`RuleRuntime`） |
| `fountain::f_rule.exception` | `RuleException` / `RuleErrorCode`（27 个） |
| `fountain::f_rule.fact` | `Fact` / `FactSchema` / `TypedFact` / `DynamicFact` / `FactSpace` / `FactBase` |
| `fountain::f_rule.condition` | 算子、约束、模式、条件树、`JitExpression` 与内置解释器 |
| `fountain::f_rule.rule` | `Rule` / `RuleSet` / 构建器 / 校验器 / 冲突键 |
| `fountain::f_rule.rete` | alpha/beta 节点、索引、令牌、按空间分片的会话网络 |
| `fountain::f_rule.agenda` | 议程、激活、冲突消解、动作上下文、循环检测 |
| `fountain::f_rule.engine` | `RuleEngine` / `RuleSession` / `EngineOptions` |
| `fountain::f_rule.table` | 决策表三载体、编译、执行、命中聚合 |
| `fountain::f_rule.flow` | `RuleFlow` / `RuleSetFlow` / `RuleTask` / `ResolveTask` / `JoinTask` / `RuleEnvelope` |

包依赖方向单向，禁止反向：`runtime → exception → fact → condition → rule → rete → engine → flow`，`agenda` 与 `table` 在 `rule` 之上并入 `engine`。子包**不能** `import fountain::f_rule.*`（会形成包循环）。

## 构建与测试

```bash
cd f_rule
cjpm build
cjpm test

# 只跑功能回归，跳过性能门禁与规模用例
cjpm test --exclude-tags=perf

# 带上性能门禁（B-01~B-07）并输出 BENCH 明细
cjpm test --include-tags=perf --no-capture-output
```

| 项 | 实测 |
|---|---|
| 用例 | `--exclude-tags=perf` 与 `--include-tags=perf` 均为 446 用例、0 失败（2026-11-02，x86_64 WSL，`cjc 1.3.0-alpha`） |
| 冷构建（含全部路径依赖） | 约 4 分钟（aarch64 Linux / 7 核） |
| 增量构建 | 约 3 秒 |
| `cjpm test` 全量（含性能门禁） | 约 2m45s |
| `cjpm test --exclude-tags=perf` | 约 1m20s |

性能门禁（阈值是验收合同；下表实测值取自 aarch64 Linux / 7 核，与 [doc/perf.md](doc/perf.md) 同一轮测量）：

| 编号 | 场景 | 门禁 | 实测 |
|---|---|---|---|
| B-01 | 1000 规则（每规则 2 模式）构建网络 | < 500 ms，节点 < 3000 | 58.12 ms，节点 1200 |
| B-02 | 10000 事实插入 | < 2 s，激活数与朴素一致 | P95 1161.71 ms，激活 1000 = 朴素 1000 |
| B-03 | 网络已建后单条插入 | P95 < 1 ms | P95 0.116 ms |
| B-04 | 撤销 30% 事实 | < 500 ms | 176.41 ms |
| B-05 | 1000 规则 / 10000 事实 RSS | < 512 MB | 188.85 MB（增量 140.30 MB） |
| B-06 | 重复构建同一规则集 | < 50 ms | P95 0.000157 ms |
| B-07 | 1000 行决策表解析 + 编译 | < 300 ms | P95 16.35 ms |

## 状态与已知边界

**可用**：M0~M7 全部完成，`cjpm test` 全量通过，性能门禁 B-01~B-07 全部达标。

- **决策表在议程路径有四项 `HitPolicy` 降级**（`Unique` 运行期多命中不报错、`Priority` 降级行序、`Any` 不校验输出一致、`OutputOrder` 按行序）。需要完整语义用 `executeTable`，见 [doc/07](doc/07-decision-table.md) §2.1。
- **B-02 的余量约 42%**（1162 ms / 2000 ms），后续改动涉及插入路径必须重跑门禁。
- **`cjlint` 未清零仓库风格类告警**：正确用法是 `cjlint -f ./src -m $CANGJIE_HOME`（`-m` 指 SDK 根，不是 `modules` 子目录）。代码级 error 已归零，剩余主要是 `G.OTH.03`（License 头 URL 硬编码）、`G.PKG.01`（wildcard import）、`G.NAM.*`（PascalCase 文件名、全大写错误码枚举）——这些是全仓库统一风格（`f_egraph` 同样存在），需项目级 `cjlintignore.cfg` 统一处理。
- **`cjfmt` 默认配置与项目 License 头惯例冲突**：全仓库（含 `f_egraph` 等既有模块）统一写 `*/`，`cjfmt` 期望 ` */`。未为通过检查而批量改写。

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

## 许可

Apache-2.0
