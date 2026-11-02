# `fountain::f_rule` rule engine

A rule engine built on [`f_egraph`](../f_egraph/README.md) and [`f_jit`](../f_jit/README.md): fact bases, a Rete network, an agenda, decision tables and decision flows. Declarative rules, decision tables and `f_jit` scripts share the same fact model and the same `Compiler`.

## Capabilities

| Capability | Description |
|---|---|
| Two fact shapes | `TypedFact<T>` + `FactSchema<T>` (typed business classes whose fields can be read by scripts) and `DynamicFact` (dynamic dictionaries evaluated by the built-in interpreter) |
| Multiple fact bases | A rule set may declare several `FactSpace`s; a rule belongs to exactly one space, the Rete network is sharded per space, and joins never cross spaces |
| Condition evaluation | 15 operators + three-valued logic; condition tree `And`/`Or`/`Not`/`Leaf`/`Join`/`Script`; `ExpressionMode.Interpreted` forces the interpreter |
| Rete network | Alpha/beta sharing by signature, equality/range indexes, token parent-chain sharing + reference counting, incremental insert and retract |
| Agenda | 6 conflict-resolution strategies + `CompositeResolver`, 3 `FireMode`s, mutual-exclusion `activationGroup`, cycle detection |
| Decision tables | Builder API / CSV / XLSX, 7 `HitPolicy`s; aggregated execution (`executeTable`) or compiled into the agenda (`RuleSetBuilder.table`) |
| Decision flows | One `f_egraph.Flow` per rule; fan-out via `ResolveTask`, join via `JoinTask` (with optional timeout) |
| Engine facade | `RuleEngine` / `RuleSession`; `fire` / `fireDetailed`; table executors cached by `(id, version)` |

## Quick start

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
        .facts("orders")                                  // fact base the rule belongs to
        .addPattern(Pattern("Order", "o")                 // typeTag + binding name
            .constrain("level", Operator.Ge, 3)
            .constrain("amount", Operator.Gt, 200))
        .then({ ctx => ctx.set("discount", 0.85) })       // output slot
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

The package root `fountain::f_rule` re-exports only the common types; import the sub-packages for the rest:

| What you need | Import |
|---|---|
| `FieldType`, `FactBase`, `FactBaseView`, `FactSpaceRegistry`, `TypeTag` | `fountain::f_rule.fact` |
| `Constraint`, `Operand`, `JoinConstraint`, `ConditionExpr`, `ExpressionMode`, `Truth` | `fountain::f_rule.condition` |
| `ActionContext`, `ConflictResolver`, `RuleSetStatus` | `fountain::f_rule.rule` |
| `Resolvers` and the 6 strategies, `CycleDetector` | `fountain::f_rule.agenda` |
| `EngineOptions` | `fountain::f_rule.engine` |
| `RuleException`, `RuleErrorCode` | `fountain::f_rule.exception` |
| `TableExecutor`, `TableCompiler`, `HitAggregator` | `fountain::f_rule.table` |

## Core concepts

| Concept | Type | Description |
|---|---|---|
| Fact | `Fact` / `TypedFact<T>` / `DynamicFact` | Field-addressable data unit; immutable once inside the network |
| Type description | `FactSchema<T>` / `FactSpace` | Field names + `FieldType` + getters; `typeTag` is the key rules use to reference a type |
| Fact space | `FactSpace` | Namespace; the same id shares facts and network shards, `default` when omitted |
| Fact view | `FactBaseView` | Container per `(space, session)`: `assert` / `retract` / `update` / `scan` / `copyTo` / `fork` |
| Pattern | `Pattern` | Type + binding name + constraint set |
| Constraint | `Constraint` / `JoinConstraint` | Single-fact predicate / cross-pattern field comparison |
| Rule | `Rule` | Patterns + joins + script conditions + actions + space + `salience` + `activationGroup` |
| Rule set | `RuleSet` | Rules + space registry + version + expression mode + conflict resolver; frozen after build |
| Activation | `Activation` | One rule under one binding set; `seq` is monotonic and only breaks ties |
| Agenda | `Agenda` | Session-level priority queue, sorted across spaces |
| Session | `RuleSession` | Facts + Rete runtime + agenda |

## Four typical usages

### 1. Production mode

Rules are compiled into the Rete network; asserting a fact triggers incremental matching and the agenda fires activations in conflict-resolution order. Multi-pattern rules are connected with `JoinConstraint`:

```cangjie
// assuming a User type is registered the same way as Order
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

Extra script conditions go through `.script(...)`; the source is compiled by `RuleSet.build()` and its parameters must be pattern bindings:

```cangjie
let risky = Rule.builder("R3")
    .addPattern(Pattern("Order", "o"))
    .script("{ o: Order => o.amount * 2 > 1000 }")
    .then({ ctx => ctx.set("flag", true) })
    .build()
```

### 2. Decision table: aggregated execution

Evaluate the whole table and aggregate with `HitPolicy`; the result is a `TableResult` (with per-row `RowTrace`) and never enters the agenda. Use it when a batch of facts has exactly one table-determined outcome:

```cangjie
import fountain::f_rule.*
import std.fs.Path

main() {
    let table = CsvTableParser.parseFile(Path("./rules/pricing.csv"))

    let ruleSet = RuleSetBuilder(table.id)              // aggregated path needs only space and types
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
    for (row in result.trace) {                          // why a row did not match
        println("${row.ruleId}: matched=${row.matched}")
    }
}
```

`TableResult.hits` and `TableResult.outputs` correspond by index; `trace` is non-empty only with `trace: true`.

### 3. Decision table: compiled into the agenda

Each row is compiled into a rule that is ordered on the same agenda as hand-written rules. Use it when the table is a decision matrix that must be mutually exclusive with, or ranked against, code rules:

```cangjie
import fountain::f_rule.*
import std.fs.Path

main() {
    let pricing = XlsxTableParser.parse(Path("./rules/pricing.xlsx"), "pricing")

    let ruleSet = RuleSetBuilder("pricing")
        .version("v1")
        .factSpace("orders")
        .registerFact("orders", orderSchema())
        .table(pricing)                   // table rules: row id is the rule id
        .rule(manualOverride)             // hand-written rule (omitted); may share activationGroup with table rules
        .build()

    let engine = RuleEngine(ruleSet)
    let session = engine.session("order-1001")
    let _ = session.assert("orders", TypedFact(Order("1001", 500, 3), orderSchema()))
    let _ = session.fire()
}
```

A table instance **cannot** take both paths: calling `executeTable` on an assembled table throws `TABLE_MODE_CONFLICT`, and vice versa. The exclusion is per instance; different instances are independent.

### 4. Decision flow

When the order of rules or parallel branches must be explicit, give each rule an `f_egraph.Flow`:

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
    // `engine` comes from "Production mode" above; the two branch rules live in orders / users
    let builder = RuleSetFlow.build(engine)
        .start("order.created")
        .fanout("order.created", [
            ("order.vip.check", "pricing/R1"),
            ("order.bulk.check", "pricing/R2")     // the branches must use different fact spaces
        ])

    // Branch handlers hang off the same underlying flow; RuleTask asserts facts and fires the agenda
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

`RuleSetFlow` only assembles the orchestration tasks `ResolveTask` / `JoinTask`; which rule runs in a branch and which space it reads is decided by the `RuleTask`s registered on `flow`. A `JoinTask` timeout relies on `f_ticktock`; when the scheduler is not initialized the constructor logs a WARN and runs without a timeout.

## Decision table file format

### CSV

```csv
# f_rule decision table v1
# id: pricing
# name: order discount
# version: v1
# factSpace: orders
# factType: Order
# hitPolicy: First
# salience: 100
id,name,when.order.level,when.order.amount,then.discount,then.event
R1,vip large,>=3,>200,0.85,order.discounted
R2,regular large,>=1,>500,0.90,order.discounted
R3,fallback,,,1.0,order.discounted
```

- `# key: value` lines are table properties (keys are case-insensitive); `id` is required and any other `#` line is a comment. The file must be UTF-8 (a BOM is skipped); quoting and escaping follow RFC 4180.
- The first non-comment line is the header, every following line is one rule; all rows must have the same column count as the header, and error messages carry the physical line number.
- An empty `id` cell is auto-numbered `R1`, `R2`, …
- Supported properties: `id`, `name`, `version` (default `v1`), `factSpace` (default `default`), `factType`, `hitPolicy` (default `First`), `salience`, `outputOrder` (comma separated).

### XLSX

- The sheet name is the table id; row 1 is the header, row 2 is an optional type row (every non-empty cell must be one of `number`/`text`/`bool`/`time`/`list`, otherwise the row is treated as data), and data starts at row 3 (row 2 when there is no type row).
- A `_meta` sheet carries the properties above as key/value pairs.
- Every sheet except `_meta` is one table; the whole-table path expands merged cells, the streaming path does not and logs a WARN at end of stream.
- `Error` cells and `Formula` cells without a cached value throw `TABLE_INVALID` (a formula with a cached value is rendered from the cache).
- For large tables use `XlsxTableParser.stream(path)`: `DecisionTable.rows` stays empty and `rowIterator()` reads on demand, so memory does not grow with the row count.

### Headers and cells

| Column | Meaning |
|---|---|
| `id` / `name` | Row id (rule id) and row name |
| `salience` | Row priority (integer) |
| `when.<field>` / `when.<binding>.<field>` | Condition column; the binding may be omitted on single-pattern tables (default `o`), and all condition columns must use the same binding |
| `then.<output>` | Output slot name |
| `expr.<column>` | Bare boolean expression (`f_jit` or the interpreter) wrapped with the same binding |

Condition cells (operator names are case-insensitive):

| Syntax | Operator |
|---|---|
| empty / `-` | no constraint |
| `null` / `not null` | `IsNull` / `NotNull` |
| `>=x` `<=x` `!=x` `=x` `==x` `>x` `<x` | `Ge` `Le` `Ne` `Eq` `Eq` `Gt` `Lt` |
| `in [a, b]` / `not in [a, b]` | `In` / `NotIn` |
| `between [a, b]` | `Between` (exactly two bounds) |
| `contains x` / `startswith x` / `endswith x` / `matches x` | `Contains` / `StartsWith` / `EndsWith` / `Matches` |
| any other bare value | `Eq`, parsed according to the declared `FieldType` |

Output cells: `${binding.field}` reads a field of the matched fact, `${binding}` yields the whole fact, anything else is a literal (number / bool / time / text). The binding must appear in that row's conditions, otherwise `UNKNOWN_BINDING` is thrown.

### Hit policies

| `HitPolicy` | Aggregated path (`executeTable`) | Agenda path (`table()`) |
|---|---|---|
| `Unique` | zero hits → `TABLE_NO_MATCH`, several hits → `TABLE_MULTI_MATCH` | duplicate rows checked at build time; at runtime several hits execute one row and do not raise |
| `First` | first row in row order | mutual exclusion in one group + row-order `salience` |
| `Priority` | smallest value per `outputOrder` | degraded to row order |
| `Any` | several hits must agree on outputs | output consistency is not checked |
| `Collect` | all hits, row order | all rows execute |
| `RuleOrder` | all hits, `salience` descending | all rows execute |
| `OutputOrder` | all hits, output value ascending | degraded to row order |

## API reference

### Facts

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

`DynamicFact` values accept only `String / Int64 / Float64 / Bool / DateTime / Decimal / Array<Any>` (and read-only collection shapes); any other type throws `TYPE_MISMATCH` on write. A fact is frozen when asserted into a fact base.

### Conditions

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

A condition tree enters a rule through `RuleBuilder.condition(typeTag, expr)` and is expanded by `RuleSet.build()` into DNF: every conjunction becomes one rule (`Or` naturally splits, `And(Or(A, B), C)` distributes), ids gain `#1`, `#2` when there are several, and one rule expands into at most 64 rules. Nesting is limited to depth 32; `Not` may wrap a leaf, `And` or `Or` (negation is pushed down) but not a `Join` or `Script`.

### Rule set

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

`build()` throws on validation failure; `buildOrInvalid()` leaves the failure in `RuleSet.status` (`Invalid`) for diagnostics and tests. `addPattern` / `script` correspond to `when` / `where` in the design docs — both words are Cangjie keywords, so the public API renames them.

### Engine and sessions

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

`session(id)` returns the same session for the same id; `release(id)` frees its facts, tokens and agenda. `close()` cascades to the rule set, after which any execution throws `CLOSED`.

### Agenda and conflict resolution

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

- `Refract` (default): an activation is invalidated once fired; `NoLoop`: the same rule under the same bindings fires once per `fire`; `Loop`: reactivations are allowed until the agenda is empty or `limit` is reached.
- The default chain is `salience ↓ → specificity ↓ → ruleOrder ↑ → seq ↑`, with `(factSpace, ruleId)` as the final tie-breaker. Replace it with `Resolvers.salience()` / `specificity()` / `fifo()` / `lifo()` / `ruleOrder()` / `ruleId()` / `composite([...])` / `defaultChain()`.
- Activations in the same `activationGroup` race; only the first executes and the rest are invalidated. The group name is not part of the activation equality key.
- With `enableCycleDetection(window)`, one activation fingerprint appearing more than the threshold (100) times inside the window throws `CYCLE_LIMIT`.

### Decision tables

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

When `factType` is omitted it is inferred from the single type registered in the space; a space with several types must declare it explicitly, otherwise `TABLE_INVALID` is thrown.

### Flow orchestration

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

`RuleEnvelope` carries the session: `f_egraph`'s `emit` creates a random UUID for every new event, so only the session inside the envelope keeps fan-out branches in the same session.

### Runtime

```cangjie
public class RuleRuntime {
    public static func initCompiler(compiler: Compiler): Unit
    public static func compiler(): Compiler
}
```

`RuleInitializer` is the `f_app.Initializer` implementation (depending on `fountain::f_egraph`); `initialize()` only guarantees that a shared compiler exists — rule sets are built explicitly by the application.

## Error codes

All failures raise `RuleException <: BaseException`; `code` is a `RuleErrorCode` whose `toString()` is a stable upper-snake name (logs and alerts depend on it).

| Phase | Codes |
|---|---|
| Rule set assembly | `DUPLICATE_RULE`, `EMPTY_PATTERN`, `UNKNOWN_FACT_SPACE`, `EMPTY_FACT_SPACE_SET`, `CROSS_SPACE_JOIN`, `SAME_SPACE_FANOUT`, `DUPLICATE_TYPE`, `UNKNOWN_TYPE`, `UNKNOWN_FIELD`, `UNKNOWN_BINDING`, `TYPE_MISMATCH`, `NETWORK_FROZEN` |
| Facts | `DUPLICATE_FACT`, `ILLEGAL_STATE` |
| Decision tables | `TABLE_INVALID`, `TABLE_NO_MATCH`, `TABLE_MULTI_MATCH`, `TABLE_MODE_CONFLICT` |
| Scripts | `SCRIPT_COMPILE`, `SCRIPT_BINDING_MISSING` |
| Flow orchestration | `FANOUT_WITHOUT_JOIN`, `EMPTY_FANOUT`, `NO_CONTEXT` |
| Agenda runtime | `CYCLE_LIMIT`, `REENTRANT_FIRE`, `ACTION_FAILED`, `CLOSED` |

Compile-time errors (rule definitions, decision tables, scripts) always surface during the build phase; the runtime only keeps fact type mismatches, expression runtime failures, action failures and illegal state.

## Constraints

| Constraint | Reason |
|---|---|
| Facts inside the network are immutable | Indexes and fact contents must agree; modify through `RuleSession.update()` (retract + assert and network propagation). Touching a `FactBaseView` directly only changes storage and leaves indexes stale |
| All patterns of one rule belong to the same `FactSpace` | Retraction semantics rely on a single base's lifetime; materialize cross-base data explicitly with `ActionContext.copyTo` |
| Fan-out branches must be joined by `JoinTask` | `f_egraph`'s `dispatch` returns as soon as it reaches `EndExecutor` without clearing the queue, so leftovers are consumed by the next `start()`; the builder throws `FANOUT_WITHOUT_JOIN` |
| Branches in the same `factSpace` cannot fan out | Concurrent writes to the same facts are ordered by the queue, which is not controllable; throws `SAME_SPACE_FANOUT` at build time |
| One `DecisionTable` instance takes one path only | Assembling and aggregating would fire twice; throws `TABLE_MODE_CONFLICT` |
| Streaming tables cannot be iterated concurrently | Several `rowIterator()` calls share the underlying ZIP stream; sequential iteration is safe |
| A rule set is frozen after build | Space and type descriptors become read-only; registering later throws `NETWORK_FROZEN` |
| Version switching works on `tag` | Only one active `tag` per `category`; call `removeExceptCurrentTag()` after switching |

## Initialization order

`f_jit`'s compile cache is process-wide, so `f_egraph` and `f_rule` must share one `Compiler`; otherwise script rule bodies are compiled twice and their type registrations are invisible to each other:

```cangjie
import fountain::f_jit.*
import fountain::f_jit.macros.*
import fountain::f_rule.*
import fountain::f_rule.runtime.RuleRuntime

let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
compiler.registerType<Order>()          // 1. f_jit: enroll host types used by scripts
RuleRuntime.initCompiler(compiler)      // 2. f_rule: inject the shared compiler
// 3. f_egraph / f_rule are started by f_app.InitializerCollection
```

Without `RuleRuntime.initCompiler`, the first use lazily creates a default `Compiler` and logs one WARN — that instance cannot see the application's registered types, so script conditions throw `SCRIPT_COMPILE` from `RuleSet.build()`.

## Package structure

| Package | Purpose |
|---|---|
| `fountain::f_rule` | Facade; `public import` re-exports the common declarations |
| `fountain::f_rule.runtime` | Shared `Compiler` (`RuleRuntime`) |
| `fountain::f_rule.exception` | `RuleException` / `RuleErrorCode` (27 codes) |
| `fountain::f_rule.fact` | `Fact` / `FactSchema` / `TypedFact` / `DynamicFact` / `FactSpace` / `FactBase` |
| `fountain::f_rule.condition` | Operators, constraints, patterns, condition tree, `JitExpression` and the built-in interpreter |
| `fountain::f_rule.rule` | `Rule` / `RuleSet` / builders / validator / conflict key |
| `fountain::f_rule.rete` | Alpha/beta nodes, indexes, tokens, per-space session networks |
| `fountain::f_rule.agenda` | Agenda, activations, conflict resolution, action context, cycle detection |
| `fountain::f_rule.engine` | `RuleEngine` / `RuleSession` / `EngineOptions` |
| `fountain::f_rule.table` | Decision table carriers, compilation, execution, hit aggregation |
| `fountain::f_rule.flow` | `RuleFlow` / `RuleSetFlow` / `RuleTask` / `ResolveTask` / `JoinTask` / `RuleEnvelope` |

Package dependencies are one-directional: `runtime → exception → fact → condition → rule → rete → engine → flow`, with `agenda` and `table` joining above `rule` and feeding `engine`. Sub-packages **must not** `import fountain::f_rule.*` (that would create a package cycle).

## Build and test

```bash
cd f_rule
cjpm build
cjpm test

# functional regression only, skipping performance gates and scale cases
cjpm test --exclude-tags=perf

# include the performance gates (B-01~B-07) and print the BENCH details
cjpm test --include-tags=perf --no-capture-output
```

| Item | Measured |
|---|---|
| Test cases | 446 cases, 0 failures with both `--exclude-tags=perf` and `--include-tags=perf` (2026-11-02, x86_64 WSL, `cjc 1.3.0-alpha`) |
| Cold build (all path dependencies) | about 4 minutes (aarch64 Linux / 7 cores) |
| Incremental build | about 3 seconds |
| `cjpm test` (full, with performance gates) | about 2m45s |
| `cjpm test --exclude-tags=perf` | about 1m20s |

Performance gates (thresholds are an acceptance contract; the measured values below come from aarch64 Linux / 7 cores, the same run as [doc/perf.md](doc/perf.md)):

| Gate | Scenario | Threshold | Measured |
|---|---|---|---|
| B-01 | Build a network of 1000 rules (2 patterns each) | < 500 ms, nodes < 3000 | 58.12 ms, 1200 nodes |
| B-02 | Insert 10000 facts | < 2 s, activations match the naive matcher | P95 1161.71 ms, 1000 activations = naive 1000 |
| B-03 | Single insert after the network is built | P95 < 1 ms | P95 0.116 ms |
| B-04 | Retract 30% of the facts | < 500 ms | 176.41 ms |
| B-05 | RSS for 1000 rules / 10000 facts | < 512 MB | 188.85 MB (delta 140.30 MB) |
| B-06 | Rebuild the same rule set | < 50 ms | P95 0.000157 ms |
| B-07 | Parse + compile a 1000-row decision table | < 300 ms | P95 16.35 ms |

## Status and known limits

**Usable**: milestones M0–M7 are complete, the full `cjpm test` suite passes, and performance gates B-01–B-07 all pass.

- **Four `HitPolicy` degradations on the agenda path** (`Unique` does not raise on multiple runtime hits, `Priority` falls back to row order, `Any` does not check output consistency, `OutputOrder` falls back to row order). Use `executeTable` for the complete semantics; see [doc/07](doc/07-decision-table.md) §2.1.
- **B-02 has about 42% headroom** (1162 ms / 2000 ms); any change touching the insert path must re-run the gates.
- **`cjlint` still reports repository-style warnings**: run it as `cjlint -f ./src -m $CANGJIE_HOME` (`-m` points at the SDK root, not the `modules` sub-directory). Code-level errors are down to zero; the remaining warnings are mostly `G.OTH.03` (hard-coded license URL), `G.PKG.01` (wildcard imports) and `G.NAM.*` (PascalCase file names, upper-case error enums) — repository-wide conventions that `f_egraph` shares, to be handled by a project-level `cjlintignore.cfg`.
- **`cjfmt`'s default configuration conflicts with the license-header convention**: the whole repository (including `f_egraph`) writes `*/` while `cjfmt` expects ` */`. The headers were not rewritten just to satisfy the checker.

## Documentation

Full technical documentation lives in [`doc/`](doc/README.md):

| Document | Content |
|---|---|
| [doc/01-architecture.md](doc/01-architecture.md) | Layering, package dependency direction, core data flows, error codes |
| [doc/02-fact-model.md](doc/02-fact-model.md) | Fact model, `FactSpace`, two-dimensional session isolation |
| [doc/03-condition-expression.md](doc/03-condition-expression.md) | Operators, condition tree, `f_jit` expressions and the interpreter |
| [doc/04-rete-network.md](doc/04-rete-network.md) | Rete network, node sharing, indexes, incremental insert and retract |
| [doc/05-agenda-conflict-resolution.md](doc/05-agenda-conflict-resolution.md) | Agenda, conflict resolution, `activationGroup`, loop control |
| [doc/06-flow-orchestration.md](doc/06-flow-orchestration.md) | Rule flows, `ResolveTask`, `JoinTask` |
| [doc/07-decision-table.md](doc/07-decision-table.md) | Three carriers, 7 hit policies, differences between the two execution paths |
| [doc/08-api.md](doc/08-api.md) | Public API and complete examples |
| [doc/09-testing.md](doc/09-testing.md) | Test matrix (including I-01~I-06) and performance gates |
| [doc/10-roadmap.md](doc/10-roadmap.md) | Milestones and acceptance criteria |
| [doc/11-assembly.md](doc/11-assembly.md) | Assembly layer: `table()` / `executeTable()` and the package-dependency solution |
| [doc/perf.md](doc/perf.md) | Measured values and methodology for B-01~B-07 |

## Dependencies

| Module | Purpose |
|---|---|
| `fountain::f_egraph` | Flows, events, tasks |
| `fountain::f_jit` | Expression compilation and scripted rule bodies |
| `fountain::f_excel` | XLSX decision table reading |
| `fountain::f_regex` | `Matches` operator |
| `fountain::f_app` | `Initializer` registration (`RuleInitializer`) |
| `fountain::f_ticktock` | `JoinTask` timeout timer |
| `fountain::f_base` / `f_collection` / `f_concurrent` / `f_log` / `f_util` | Infrastructure |

## License

Apache-2.0
