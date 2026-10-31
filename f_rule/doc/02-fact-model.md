# 02 事实模型

## 1. 设计目标

1. **双形态**：业务既有已存在的强类型 POJO（`Order`、`User`），也有配置驱动的动态数据（JSON 行、CSV 行）。两者必须能进入同一张网络。
2. **网络友好**：alpha 网络要按类型分桶，join 要按字段建索引，因此事实必须支持**按字段名取值**且**类型标签稳定**。
3. **不可变**：事实一旦进入网络，其字段值在其生命周期内不得变化，否则索引失效。

## 2. 核心契约

```cangjie
package fountain::f_rule.fact

/**
 * 可字段寻址的事实。
 *
 * 实现方必须保证：进入 Rete 网络后，[get] 的返回值不再变化。
 * 需要修改时走 FactBase.update()，内部等价于 retract + assert。
 */
public interface Fact {
    /** 类型标签，alpha 网络的分桶键。同一业务类型必须恒定。 */
    prop typeTag: String
    /** 按字段名取值。字段不存在返回 None；字段存在但值为空也应返回 None。 */
    func get(field: String): ?Any
    /** 字段是否存在（与值为 None 区分）。 */
    func has(field: String): Bool
}

/**
 * 网络内部的事实句柄。
 *
 * 网络传播与索引只持有句柄（Int64 id + typeTag），不直接持有事实对象，
 * 避免大量 token 长期滞留业务对象；需要取值时回查 FactBase。
 */
public class FactHandle <: Hashable & Equatable<FactHandle> {
    public FactHandle(public let id: Int64, public let typeTag: String)
    public func hashCode(): Int64
    public operator func ==(other: FactHandle): Bool
}
```

`FactHandle` 相等性只看 `id`，`typeTag` 仅用于调试与桶定位。id 由 `FactBase` 单调分配，进程内唯一。

## 3. 强类型事实

### 3.1 字段访问器

强类型事实不要求业务类实现 `Fact`。通过 `FactSchema<T>` 注册字段访问器（闭包），把任意类适配成事实：

```cangjie
/** 字段静态类型，用于构建期校验与决策表单元格解析。 */
public enum FieldType {
    /** 字符串 / 数字 / 布尔 / 时间 */
    | Scalar
    | Number
    | Text
    | Bool
    | Time
    | List
    | Any
}

public class FactSchema<T> {
    /**
     * @param typeTag 类型标签，规则与决策表中引用该类型时使用同一字符串
     */
    public init(typeTag: String)

    /**
     * 注册一个字段访问器，静态类型按 Any 处理。
     * @param name 字段名，规则侧按此名引用
     * @param getter 从宿主对象取值
     */
    public func field(name: String, getter: (T) -> Any): FactSchema<T>

    /** 注册字段访问器并声明静态类型，供构建期校验使用。 */
    public func field(name: String, type: FieldType, getter: (T) -> Any): FactSchema<T>

    public prop typeTag: String
    public func lookup(name: String): ?((T) -> Any)
    public func fieldType(name: String): FieldType
    public func names(): Array<String>
}
```

用法：

```cangjie
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

let orderSchema = FactSchema<Order>("Order")
    .field("id", { o => o.id })
    .field("amount", FieldType.Number, { o => o.amount })
    .field("level", FieldType.Number, { o => o.level })
```

闭包作为显式实参传入，不用尾随闭包语法：`field` 有两个重载，尾随闭包会与重载解析冲突。

`FactSchema` 在 `RuleSet` 构建期注册一次，之后不可变：

```cangjie
ruleSet.registerFact(orderSchema)
```

### 3.2 适配器

```cangjie
public class TypedFact<T> <: Fact {
    public init(value: T, schema: FactSchema<T>)
    public prop typeTag: String
    public func get(field: String): ?Any
    public func has(field: String): Bool
    /** 取回原始对象，供宿主侧动作使用；返回值与注册时同一引用。 */
    public prop value: T
}
```

`TypedFact` 不做字段拷贝，`get` 每次调用 `getter`。因此**业务对象在事实生命周期内必须不可变**；若业务需要可变对象，插入前用 `FactBase.assertCopy()` 拷贝字段到 `DynamicFact`。

## 4. 动态事实

```cangjie
public class DynamicFact <: Fact {
    public init(typeTag: String)
    public init(typeTag: String, values: HashMap<String, Any>)
    public prop typeTag: String
    public func get(field: String): ?Any
    public func has(field: String): Bool
    public func set(field: String, value: Any): Unit
    public func remove(field: String): Unit
    /**
     * 冻结：之后 set/remove 抛 RuleException(ILLEGAL_STATE)。
     * FactBase.assert 会自动冻结传入的 DynamicFact。
     */
    public func freeze(): Unit
    public prop frozen: Bool
}
```

动态事实的字段值只允许以下类型，其余在 `assert` 阶段抛 `TYPE_MISMATCH`：

```
String / Int64 / Float64 / Bool / DateTime / Decimal / Array<Any> / Set<Any>
```

不支持嵌套 `Fact`（需要关联查询时拆成多条事实 + join 约束）。

## 5. 值规范化

索引与算子比较需要稳定的相等性。引入 `ValueKey`：

```cangjie
/**
 * 索引键。数值跨类型归一：Int64(1) 与 Float64(1.0) 相等；
 * 字符串不做大小写折叠（需要时在规则里用 lower()/upper() 表达式）。
 *
 * 公开是因为 AlphaMemory 的 probe/range 以它为形参；构造与归一逻辑仅模块内部使用。
 */
public class ValueKey <: Hashable & Equatable<ValueKey> {
    static func of(v: Any): ValueKey
    public func hashCode(): Int64
    public operator func ==(other: ValueKey): Bool
}
```

归一规则：

| 输入 | 归一后 |
|---|---|
| `Int64` / `Int32` / `Int16` / `Int8` | `Int64`，超出范围抛 `TYPE_MISMATCH` |
| `Float64` / `Float32` | `Float64` |
| `Decimal` | 保留 `Decimal`，与 `Int64` 比较时提升 |
| `String` | 原样 |
| `Bool` | 原样 |
| `DateTime` | 转为 Unix 纳秒 `Int64` |
| `Array` / `Set` | 保序/去重后转 `ArrayList<ValueKey>` |

排序（`Gt`/`Lt` 等）只在同域内进行：数值域、字符串域、时间域。跨域比较抛 `TYPE_MISMATCH`，不做隐式转换（除 `Int64`/`Float64`/`Decimal` 之间）。

## 6. FactBase

```cangjie
public class FactBase {
    public init(ruleSetId: String)

    /** 插入事实，返回句柄。重复插入同一对象视为错误。 */
    public func assert(fact: Fact): FactHandle

    /** 拷贝字段后插入，用于可变业务对象。 */
    public func assertCopy(fact: Fact): FactHandle

    /** 撤销事实。不存在时静默返回 false。 */
    public func retract(handle: FactHandle): Bool

    /** 等价于 retract + assert，保留原 handle（id 复用）。 */
    public func update(handle: FactHandle, fact: Fact): Bool

    public func get(handle: FactHandle): ?Fact

    /** 按类型枚举事实句柄，用于调试与批量操作。 */
    public func scan(typeTag: String): Array<FactHandle>

    public func size(): Int64
    public func clear(): Unit
}
```

### 6.1 分桶

```
FactBase
└── buckets: Map<String /*typeTag*/, FactBucket>
    └── FactBucket
        ├── facts: Map<Int64 /*id*/, Fact>
        └── index: 由 AlphaMemory 自己维护（FactBase 不建业务索引）
```

`FactBase` 只负责存储与 id 分配；索引属于 alpha/beta memory，避免两处索引不同步。

### 6.2 会话隔离

```cangjie
/**
 * 会话级事实视图。多个流程会话并发执行时，各自看到独立的事实集合；
 * 规则集级的类型注册与网络结构全局共享。
 */
public class FactBaseView {
    public init(base: FactBase, session: String)
    public func assert(fact: Fact): FactHandle
    public func retract(handle: FactHandle): Bool
    public func get(handle: FactHandle): ?Fact
    public func scan(typeTag: String): Array<FactHandle>
    public func fork(childSession: String): FactBaseView
    public func commitToParent(): Unit
}
```

隔离级别：

| 级别 | 行为 |
|---|---|
| `Isolated`（默认） | 子视图事实对父不可见，`commitToParent` 时合并 |
| `Shared` | 直接读写父视图，用于规则流内共享同一批事实 |

规则流默认用 `Shared`：`FlowContext.of(session)` 返回同一个 `FactBaseView`。产生式模式下若需试算，用 `Isolated` 分支，确认后再 `commitToParent`。

### 6.3 生命周期

```
RuleSet 构建 ──▶ FactBase（空）
                     │
assert ──▶ bucket ──▶ AlphaMemory（索引）──▶ Beta 传播 ──▶ Agenda
                     │
retract ─◀── 引用计数归零 ◀── Beta 撤回 ◀── Activation 撤回
```

`retract` 必须同步撤回该事实触发的所有 token 与 activation；不允许"事实已删、激活仍可执行"。

## 7. 与 f_jit 的衔接

强类型事实在脚本中的用法：业务类加 `@JitBind`，并向编译器登记。

```cangjie
let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
compiler.registerType<Order>()
```

登记后 f_jit 表达式可直接访问字段：

```cangjie
let expr = JitExpression.of("{ o: Order => o.amount > 200 && o.level >= 3 }")
expr.eval([order])
```

动态事实不要求 `@JitBind`：`DynamicFact` 由 `f_rule` 登记一次，脚本通过 `get` 访问：

```cangjie
let expr = JitExpression.of(
    '{ f: DynamicFact => f.get("amount") > 200 }'
)
```

> **风险 R1**：`DynamicFact.get` 返回 `?Any`。f_jit 对 `Option<T>` 与 `Any` 的支持面需要在 M1 做 spike 验证；若不支持，动态事实的表达式条件统一降级为内置解释器（见 `03-condition-expression.md` §6），不影响 `Operator` 条件。

## 8. 事实注册校验

`RuleSet.build()` 阶段做一次全量静态校验：

| 检查 | 失败码 |
|---|---|
| 规则的每个 `Pattern.typeTag` 已注册 | `UNKNOWN_TYPE` |
| 约束的每个 `field` 在该类型的 `FactSchema.names()` 中 | `UNKNOWN_FIELD` |
| 算子与字段的静态类型兼容（可静态判定时） | `TYPE_MISMATCH` |
| `JoinConstraint` 两侧字段都存在 | `UNKNOWN_FIELD` |
| 决策表的 `when.<field>` 全部可解析 | `TABLE_INVALID` |

校验失败在构建期抛出，规则集进入 `Invalid` 状态，不得启动。
