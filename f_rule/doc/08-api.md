# 08 对外 API

## 1. 导入

```cangjie
import fountain::f_rule.*
import fountain::f_rule.fact.*
import fountain::f_rule.condition.*
import fountain::f_rule.rule.*
import fountain::f_rule.rete.*
import fountain::f_rule.agenda.*
import fountain::f_rule.flow.*
import fountain::f_rule.table.*
```

包根 `f_rule.cj` 重导出常用类型，常规用法只需 `import fountain::f_rule.*`。

## 2. 门面总览

| 类型 | 职责 | 线程安全 |
|---|---|---|
| `RuleSet` | 规则集：注册事实、装配规则、构建网络 | 构建期单线程；构建后只读 |
| `RuleEngine` | 运行时：按 session 创建会话、插入事实、触发议程 | 是 |
| `FactBase` / `FactBaseView` | 事实存储与视图 | 是 |
| `DecisionTable` | 决策表模型与编译 | 构建期单线程 |
| `RuleSetFlow` | 决策流编排 | 由 `f_egraph` 保证 |

## 3. RuleSet

```cangjie
public class RuleSet {
    public static func builder(id: String): RuleSetBuilder
    public prop id: String
    public prop version: String
    public prop rules: Array<Rule>
    public func close(): Unit
}

public class RuleSetBuilder {
    public func version(version: String): RuleSetBuilder
    /** 注册强类型事实的字段访问器。 */
    public func registerFact<T>(schema: FactSchema<T>): RuleSetBuilder
    /** 注册动态事实的类型标签（无需字段声明）。 */
    public func registerDynamicType(typeTag: String, fields: Array<String>): RuleSetBuilder
    public func rule(rule: Rule): RuleSetBuilder
    public func rules(rules: Array<Rule>): RuleSetBuilder
    public func table(table: DecisionTable): RuleSetBuilder
    /** 表达式求值模式，缺省 JitPreferred。 */
    public func expressionMode(mode: ExpressionMode): RuleSetBuilder
    /** 冲突消解策略，缺省 salience → specificity → ruleOrder → seq。 */
    public func conflictResolver(resolver: ConflictResolver): RuleSetBuilder
    public func build(): RuleSet
}
```

构建期做全量校验（见 02 §8、03 §2.2），失败抛 `RuleException` 且 `RuleSet` 不可用。

## 4. Rule

```cangjie
public class Rule {
    public static func builder(id: String): RuleBuilder
    public prop id: String
    public prop salience: Int64
    public prop patterns: Array<Pattern>
    public prop joins: Array<JoinConstraint>
    public prop actions: Array<RuleAction>
}

public class RuleBuilder {
    public func salience(value: Int64): RuleBuilder
    public func when(pattern: Pattern): RuleBuilder
    public func join(constraint: JoinConstraint): RuleBuilder
    /** 脚本条件，形参必须与已声明的绑定名一致。 */
    public func where(source: String): RuleBuilder
    public func then(action: (ActionContext) -> Unit): RuleBuilder
    public func build(): Rule
}
```

## 5. 完整示例：产生式模式

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
    // 1. 事实 schema
    let orderSchema = FactSchema<Order>("Order")
        .field("id", { o => o.id })
        .field("amount", FieldType.Number, { o => o.amount })
        .field("level", FieldType.Number, { o => o.level })

    // 2. 规则
    let vip = Rule.builder("R1")
        .salience(100)
        .when(Pattern("Order", "o")
            .where("level", Operator.Ge, 3)
            .where("amount", Operator.Gt, 200))
        .then { ctx =>
            ctx.set("discount", 0.85)
            ctx.set("event", "order.discounted")
        }
        .build()

    let fallback = Rule.builder("R2")
        .salience(0)
        .when(Pattern("Order", "o"))
        .then { ctx => ctx.set("discount", 1.0) }
        .build()

    // 3. 规则集
    let ruleSet = RuleSet.builder("pricing")
        .version("v1")
        .registerFact(orderSchema)
        .rule(vip)
        .rule(fallback)
        .build()

    // 4. 引擎
    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    session.assert(TypedFact(Order("1001", 500, 3), orderSchema))

    // 5. 触发
    let outputs = session.fire()
    println(outputs.get("discount").getOrThrow())       // 0.85
}
```

## 6. 完整示例：决策表（CSV）

```cangjie
import fountain::f_rule.*
import fountain::f_rule.table.*
import std.fs.Path

main() {
    // orderSchema 沿用 §5 的定义
    let table = CsvTableParser.parseFile(Path("./rules/pricing.csv"))
    let ruleSet = RuleSet.builder(table.id)
        .version(table.version)
        .registerFact(orderSchema)
        .table(table)
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    session.assert(TypedFact(Order("1001", 500, 3), orderSchema))

    let result = engine.executeTable(table, session)
    for (output in result.outputs) {
        println(output.get("discount").getOrThrow())
    }
}
```

## 7. 完整示例：决策流

```cangjie
import fountain::f_rule.*
import fountain::f_egraph.*

main() {
    let rs = RuleSet.builder("pricing")
        .version("v1")
        .registerFact(orderSchema)
        .rule(vip)
        .rule(bulk)
        .build()

    let engine = RuleEngine(rs)
    let flow = RuleSetFlow.build(engine)
        .start("order.created")
        .fanout("order.created", [
            ("order.vip.check", "pricing/R1"),
            ("order.bulk.check", "pricing/R2")
        ])
        .join(["order.vip.done", "order.bulk.done"], "order.priced")
        .end()
        .flow

    let order = Order("1001", 500, 3)
    let envelope = RuleEnvelope(
        session: "order-1001", ruleSetId: "pricing", payload: order)
    let end = flow.start(envelope).get().get()
    println(end.data)
}
```

`RuleSetFlow` 的链式 API 是对 `ImmediateFlow` + `ResolveTask` + `JoinTask` 的封装，`flow` 属性可直接拿到底层 `ImmediateFlow` 做进一步定制。

## 8. RuleEngine

```cangjie
public class RuleEngine {
    public init(ruleSet: RuleSet)
    public init(ruleSet: RuleSet, options: EngineOptions)

    /** 创建/获取会话。同 id 返回同一会话。 */
    public func session(id: String): RuleSession

    /** 释放会话及其事实、令牌、议程。 */
    public func release(id: String): Bool

    /** 按决策表的 hitPolicy 执行并聚合输出。 */
    public func executeTable(table: DecisionTable, session: RuleSession): TableResult

    public prop ruleSet: RuleSet
    public func close(): Unit
}

public class EngineOptions {
    /** 会话事实释放策略。 */
    public var release: Release = Release.Discard
    /** 会话空闲超时，超时自动释放。 */
    public var idleTimeout: ?Duration = None
    /** 单次表达式求值超时。 */
    public var expressionTimeout: Duration = Duration.millisecond * 50
    /** 跟踪级别。 */
    public var trace: TraceLevel = TraceLevel.Off
}

public class RuleSession {
    public prop id: String
    public prop facts: FactBaseView
    public prop agenda: Agenda
    public func assert(fact: Fact): FactHandle
    public func retract(handle: FactHandle): Unit
    public func update(handle: FactHandle, fact: Fact): Unit
    /** 执行议程，返回最后一次动作产生的输出槽合并结果。 */
    public func fire(limit!: Int64 = -1): HashMap<String, Any>
}
```

## 9. Pattern 便捷构造

```cangjie
public class Pattern {
    public init(typeTag: String, binding: String)
    public func where(field: String, op: Operator, value: Any): Pattern
    public func where(field: String, op: Operator, rightField: String): Pattern
    public func whereNot(field: String, op: Operator, value: Any): Pattern
    /** 无条件模式：匹配该类型的所有事实。 */
    public static func any(typeTag: String, binding: String): Pattern
}
```

## 10. 生命周期

```
RuleSet.builder → build → [只读]
                              │
                   RuleEngine(ruleSet)
                              │
                     session(id) ──▶ assert / fire / retract
                              │
                        release(id)
                              │
                     engine.close() → ruleSet.close()
```

`close()` 之后：
- 所有会话失效，`fire` 抛 `RuleException(CLOSED)`；
- 网络与索引内存释放；
- 已编译的 `JitExpression` 保留在规则集级缓存中，`ruleSet.close()` 一并清空。

## 11. 错误处理

```cangjie
public class RuleException <: BaseException {
    public init(code: RuleErrorCode)
    public init(code: RuleErrorCode, message: String)
    public init(code: RuleErrorCode, message: String, caused: Exception)
    public prop code: RuleErrorCode
}
```

全部错误码见 01 §6。捕获示例：

```cangjie
try {
    let item = table.compile(ruleSet)
} catch (e: RuleException) {
    match (e.code) {
        case TABLE_INVALID => println("表结构错误: ${e.message}")
        case UNKNOWN_FIELD => println("字段未注册: ${e.message}")
        case _ => throw e
    }
}
```

## 12. 与 f_egraph / f_jit 的初始化顺序

```cangjie
// 1. 编译器（f_jit）
let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
compiler.registerType<Order>()
compiler.registerType<DynamicFact>()
compiler.registerType<ActionContext>()

// 2. 注册 f_egraph 的宿主类型
JitHostRegistry.configure(compiler)
ClosureTask.initCompiler(compiler)

// 3. f_rule 使用同一编译器（保证 CompileCache 命中）
RuleRuntime.initCompiler(compiler)

// 4. 构建规则集
let ruleSet = RuleSet.builder("pricing")...
```

顺序不可颠倒：`RuleSet.build()` 会编译 `Script` 条件，此时 `Compiler` 必须已登记全部类型。

## 13. 配置项汇总

| 配置 | 位置 | 缺省 |
|---|---|---|
| `expressionMode` | `RuleSetBuilder` | `JitPreferred` |
| `conflictResolver` | `RuleSetBuilder` | `salience → specificity → ruleOrder → seq` |
| `fireMode` | `Agenda` / `RuleSession.fire` | `Refract` |
| `expressionTimeout` | `EngineOptions` | 50ms |
| `release` | `EngineOptions` | `Discard` |
| `idleTimeout` | `EngineOptions` | 无 |
| `trace` | `EngineOptions` | `Off` |
| `enableCycleDetection` | `RuleSet` | 关闭 |
| `cycleWindow` | `RuleSet` | 10000 |
