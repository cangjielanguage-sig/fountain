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
| `RuleSet` | 规则集：声明空间、注册事实、装配规则、构建网络 | 构建期单线程；构建后只读 |
| `RuleEngine` | 运行时：按 session 创建会话、插入事实、触发议程 | 是 |
| `FactSpace` | 事实库命名空间、类型注册、规则归属 | 构建期单线程；冻结后只读 |
| `FactBase` / `FactBaseView` | `(space, session)` 级事实存储与视图 | 是 |
| `DecisionTable` | 决策表模型与编译 | 构建期单线程 |
| `RuleSetFlow` | 决策流编排 | 由 `f_egraph` 保证 |

## 3. RuleSet

```cangjie
public class RuleSet {
    public prop id: String
    public prop version: String
    public prop rules: Array<Rule>
    public func close(): Unit
}

/** 规则集构建器。放在根包，避免 `rule` 包反向依赖根包。 */
public class RuleSetBuilder {
    public init(id: String)
    public func version(version: String): RuleSetBuilder
    /** 声明一个事实库空间；规则通过 `.facts(id)` 引用。 */
    public func factSpace(id: String): RuleSetBuilder
    /** 在缺省空间 "default" 注册强类型事实的字段访问器。 */
    public func registerFact<T>(schema: FactSchema<T>): RuleSetBuilder
    /** 在指定空间注册；空间不存在时自动声明。 */
    public func registerFact<T>(space: String, schema: FactSchema<T>): RuleSetBuilder
    /** 在缺省空间注册动态事实的类型标签与字段。 */
    public func registerDynamicType(typeTag: String, fields: Array<String>): RuleSetBuilder
    /** 在指定空间注册动态类型。 */
    public func registerDynamicType(space: String, typeTag: String, fields: Array<String>): RuleSetBuilder
    public func rule(rule: Rule): RuleSetBuilder
    public func rules(rules: Array<Rule>): RuleSetBuilder
    /** 把决策表编译成规则后加入规则集；表只依赖 `TableSource` 接口。 */
    public func table(source: TableSource): RuleSetBuilder
    /** 表达式求值模式，缺省 JitPreferred。 */
    public func expressionMode(mode: ExpressionMode): RuleSetBuilder
    /** 冲突消解策略，缺省 salience → specificity → ruleOrder → seq。 */
    public func conflictResolver(resolver: ConflictResolver): RuleSetBuilder
    /** 构建并校验；失败抛 RuleException，规则集对象不可得。 */
    public func build(): RuleSet
    /**
     * 构建但不在失败时抛出：校验失败时返回处于 Invalid 状态的 RuleSet，
     * 原因由 lastError() 暴露。供测试与"预校验后再决定是否上线"的场景使用。
     */
    public func buildOrInvalid(): RuleSet
    /** 最近一次 buildOrInvalid 的失败原因；成功或未调用时为 None。 */
    public func lastError(): ?RuleException
}
```

构建期做全量校验（见 02 §8、03 §2.2），失败抛 `RuleException` 且 `RuleSet` 不可用。

## 4. Rule

```cangjie
public class Rule {
    public static func builder(id: String): RuleBuilder
    public prop id: String
    public prop salience: Int64
    /** 所属事实库空间，缺省 "default"。 */
    public prop factSpace: String
    public prop patterns: Array<Pattern>
    public prop joins: Array<JoinConstraint>
    public prop actions: Array<RuleAction>
    /** 互斥组名；同组激活只执行一个。不参与激活相等键。 */
    public prop activationGroup: ?String
}

public class RuleBuilder {
    public func salience(value: Int64): RuleBuilder
    /**
     * 绑定事实库。缺省 "default"。
     * 同一规则集内相同 id 的规则共享事实与网络分片。
     */
    public func facts(space: String): RuleBuilder
    /**
     * 互斥组：同组激活按冲突消解序取第一个执行，其余在首个执行后失效。
     * 与 Drools 的 activation-group 同义；非决策表规则也可用。
     */
    public func activationGroup(name: String): RuleBuilder
    /** 追加一个模式。`when` 是仓颉关键字，故命名为 addPattern。 */
    public func addPattern(pattern: Pattern): RuleBuilder
    public func join(constraint: JoinConstraint): RuleBuilder
    /** 脚本条件，形参必须与已声明的绑定名一致。`where` 是关键字，故命名为 script。 */
    public func script(source: String): RuleBuilder
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
        .facts("orders")
        .addPattern(Pattern("Order", "o")
            .constrain("level", Operator.Ge, 3)
            .constrain("amount", Operator.Gt, 200))
        .then { ctx =>
            ctx.set("discount", 0.85)
            ctx.set("event", "order.discounted")
        }
        .build()

    let fallback = Rule.builder("R2")
        .salience(0)
        .facts("orders")
        .addPattern(Pattern("Order", "o"))
        .then { ctx => ctx.set("discount", 1.0) }
        .build()

    // 3. 规则集：声明空间并注册类型
    let ruleSet = RuleSetBuilder("pricing")
        .version("v1")
        .factSpace("orders")
        .registerFact("orders", orderSchema)
        .rule(vip)
        .rule(fallback)
        .build()

    // 4. 引擎
    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    session.assert("orders", TypedFact(Order("1001", 500, 3), orderSchema))

    // 5. 触发
    let outputs = session.fire()
    println(outputs.get("discount").getOrThrow())       // 0.85
}
```

## 6. 完整示例：决策表（CSV）

`RuleSetBuilder.table()` 接受 `TableSource`——`rule` 包定义的最小契约，`DecisionTable` 实现它：

```cangjie
public interface TableSource {
    /** 编译成规则；`registry` 用于校验条件/输出列引用的字段。 */
    func compileInto(registry: FactSpaceRegistry): Array<Rule>
}
```

接口只有这一个方法：表的 id、版本、空间属于表自己的编译输入，装配器不需要，`rule` 包也不该认识。自定义载体（如从数据库读的表）实现该接口即可接入装配。

```cangjie
import fountain::f_rule.*
import fountain::f_rule.table.*
import std.fs.Path

main() {
    // orderSchema 沿用 §5 的定义

    // ① 聚合路径：直接执行整表，拿到 TableResult / RowTrace
    let table = CsvTableParser.parseFile(Path("./rules/pricing.csv"))
    let ruleSet = RuleSetBuilder(table.id)
        .version(table.version)
        .registerFact(table.factSpace, orderSchema)
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    session.assert(table.factSpace, TypedFact(Order("1001", 500, 3), orderSchema))

    let result = engine.executeTable(table, session)
    for (output in result.outputs) {
        println(output.get("discount").getOrThrow())
    }

    // ② 议程路径：表编译成规则进入规则集，与代码规则一起 fire。
    //    两条路径对同一实例互斥，必须重新解析一份表。
    let agendaTable = CsvTableParser.parseFile(Path("./rules/pricing.csv"))
    let mixed = RuleSetBuilder(agendaTable.id)
        .version(agendaTable.version)
        .registerFact(agendaTable.factSpace, orderSchema)
        .table(agendaTable)
        .build()

    let mixedEngine = RuleEngine(mixed)
    let mixedSession = mixedEngine.session("order-1001")
    mixedSession.assert(agendaTable.factSpace, TypedFact(Order("1001", 500, 3), orderSchema))
    let outputs = mixedSession.fire()
    println(outputs.get("discount").getOrThrow())
}
```

## 7. 完整示例：决策流

```cangjie
import fountain::f_rule.*
import fountain::f_egraph.*

main() {
    // vip/bulk 在 orders 空间；level 在 users 空间（规则定义同 §5）
    let rs = RuleSetBuilder("pricing")
        .version("v1")
        .factSpace("orders")
        .factSpace("users")
        .registerFact("orders", orderSchema)
        .registerFact("users", userSchema)
        .rule(vip)
        .rule(bulk)
        .rule(level)
        .build()

    let engine = RuleEngine(rs)
    let flow = RuleSetFlow.build(engine)
        .start("order.created")
        // 不同空间的两条分支可以并行
        .fanout("order.created", [
            ("order.priced.check", "pricing/R1"),
            ("user.level.check", "pricing/R3")
        ])
        // 同空间的 R1 → R2 在子流程内部串联
        .join(["order.bulk.done", "user.level.done"], "order.priced")
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
    /** 规则集必须已构建且未关闭，否则抛 ILLEGAL_STATE。 */
    public init(ruleSet: RuleSet)

    /** 创建/获取会话。同 id 返回同一会话。 */
    public func session(id: String): RuleSession

    /** 释放会话及其事实、令牌、议程。 */
    public func release(id: String): Bool

    /**
     * 按决策表的 hitPolicy 执行并聚合输出；执行器按 `(id, version)` 缓存。
     * 与 `.table()` 装配路径对同一张表硬互斥（`TABLE_MODE_CONFLICT`）。
     */
    public func executeTable(table: DecisionTable, session: RuleSession,
        trace!: Bool = false): TableResult

    public prop ruleSet: RuleSet
    public prop closed: Bool
    /** 级联关闭规则集，之后任何执行抛 CLOSED。 */
    public func close(): Unit
}

/** 会话策略，M7 接入。当前版本所有会话等价于 Release.Discard + 无空闲超时。 */
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
    /** 缺省空间 "default" 的事实视图。 */
    public prop facts: FactBaseView
    /** 指定空间的事实视图；空间未声明时抛 UNKNOWN_FACT_SPACE。 */
    public func factsOf(space: String): FactBaseView
    public prop agenda: Agenda
    /** 在缺省空间插入。 */
    public func assert(fact: Fact): FactHandle
    /** 在指定空间插入。 */
    public func assert(space: String, fact: Fact): FactHandle
    public func retract(handle: FactHandle): Unit
    public func update(handle: FactHandle, fact: Fact): Unit
    /** 执行议程，返回最后一次动作产生的输出槽合并结果。 */
    public func fire(limit!: Int64 = -1): HashMap<String, Any>
    /** 同 fire，但额外返回逐条执行记录，供决策表按行聚合。 */
    public func fireDetailed(limit!: Int64 = -1): FireResult
}

public class FireResult {
    /** 最后一轮动作写入的输出槽合并结果。 */
    public let outputs: HashMap<String, Any>
    /** 按执行顺序排列的规则执行记录。 */
    public let fired: Array<FiredRule>
}
```

`factsOf` 与 `facts` 是方法/属性之分：仓颉不允许属性与方法同名，故指定空间取视图用动词化命名。

## 9. Pattern 便捷构造

`where` 是仓颉关键字，因此条件方法统一命名为 `constrain*`：

```cangjie
public class Pattern {
    public init(typeTag: String, binding: String)
    /** 字段 op 常量。 */
    public func constrain(field: String, op: Operator, value: Any): Pattern
    /** 字段 op 另一字段（join 条件）。 */
    public func constrainField(field: String, op: Operator, rightField: String): Pattern
    /** 字段 op 常量 的否定形式。 */
    public func constrainNot(field: String, op: Operator, value: Any): Pattern
    /** 无条件模式：匹配该类型的所有事实。 */
    public static func any(typeTag: String, binding: String): Pattern
}
```

## 10. 生命周期

```
RuleSetBuilder → build → [只读]
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
let ruleSet = RuleSetBuilder("pricing")...
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
