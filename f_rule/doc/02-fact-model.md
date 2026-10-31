# 02 事实模型

## 1. 设计目标

1. **双形态**：业务既有已存在的强类型 POJO（`Order`、`User`），也有配置驱动的动态数据（JSON 行、CSV 行）。两者必须能进入同一张网络。
2. **多库共存**：每条规则可以绑定独立的事实库，也可以多条规则共享同一库。共享由规则显式声明，不存在隐式跨库可见性。
3. **网络友好**：alpha 网络要按类型分桶，join 要按字段建索引，因此事实必须支持**按字段名取值**且**类型标签稳定**。
4. **不可变**：事实一旦进入网络，其字段值在其生命周期内不得变化，否则索引失效。

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

`FactSchema` 在 `RuleSet` 构建期注册一次，之后不可变；注册时必须指定空间：

```cangjie
ruleSet.registerFact("orders", orderSchema)   // 显式空间
ruleSet.registerFact(orderSchema)             // 等价于 "default"
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

## 6. 事实库

### 6.1 三级结构

```
RuleSet
└── FactSpace(id)                命名空间，构建期声明，可被多条规则引用
    └── FactBase(space, session) 会话级存储，按 (space, session) 唯一
        └── FactBucket(typeTag)  类型分桶
```

三个层次各管一件事：

| 层 | 管什么 | 生命周期 |
|---|---|---|
| `RuleSet` | 规则集合与网络结构 | 进程级 |
| `FactSpace` | 命名空间、类型注册、规则归属 | 规则集级 |
| `FactBase` | 事实存储、句柄分配 | 会话级 |

### 6.2 FactSpace

```cangjie
/**
 * 事实库命名空间。
 *
 * 一个规则集内可以有多个 FactSpace；规则通过 id 声明自己属于哪个空间。
 * 多条规则使用同一 id 即共享事实库，使用不同 id 即互相隔离。
 * 未显式声明的规则归入固定空间 "default"。
 */
public class FactSpace {
    /**
     * @param id 空间标识，规则集内唯一；"default" 为保留 id
     */
    public init(id: String)

    public prop id: String

    /** 注册强类型事实。同一 typeTag 重复注册且字段声明不一致时抛 DUPLICATE_TYPE。 */
    public func register<T>(schema: FactSchema<T>): FactSpace

    /** 注册动态类型：只声明字段名与类型，不绑定宿主类。 */
    public func registerDynamic(typeTag: String, fields: Array<(String, FieldType)>): FactSpace

    public func hasType(typeTag: String): Bool
    public func fieldNames(typeTag: String): Array<String>
    public func fieldType(typeTag: String, field: String): ?FieldType
    public func typeTags(): Array<String>
}
```

`FactSpace` 内部持有类型描述（`typeTag` → 字段名 + 字段类型 + 取值闭包），不持有事实实例。事实实例只在 `FactBase` 里。

对外不暴露 `FactSchema<Any>`：泛型不可协变，按 `typeTag` 查询字段元信息即可，具体取值在 `TypedFact` 内部完成。

### 6.3 FactBase

```cangjie
public class FactBase {
    /** 由 FactSpace + session 唯一确定，不对外直接构造。 */
    public prop space: String
    public prop session: String

    /** 插入事实，返回句柄。typeTag 未在该 space 注册时抛 UNKNOWN_TYPE。 */
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

分桶：

```
FactBase
└── buckets: Map<String /*typeTag*/, FactBucket>
    └── FactBucket
        ├── facts: Map<Int64 /*id*/, Fact>
        └── index: 由 AlphaMemory 自己维护（FactBase 不建业务索引）
```

`FactBase` 只负责存储与 id 分配；索引属于 alpha/beta memory，避免两处索引不同步。

句柄 id 在 `FactBase` 内单调分配。不同 `FactSpace` 的句柄 id 可能重复，因此 `FactHandle` 必须同时比较 `space`：

```cangjie
public class FactHandle <: Hashable & Equatable<FactHandle> {
    public FactHandle(public let space: String, public let id: Int64, public let typeTag: String)
}
```

### 6.4 规则绑定

```cangjie
public class RuleBuilder {
    /**
     * 绑定事实库。缺省 "default"。
     * 同一规则集内，相同 space 的规则共享事实、共享同一张 Rete 网络分片。
     */
    public func facts(space: String): RuleBuilder
}

public class DecisionTableBuilder {
    /** 整张决策表绑定到同一空间。 */
    public func factSpace(space: String): DecisionTableBuilder
}
```

在 `RuleSet` 层也可以批量声明：

```cangjie
public class RuleSetBuilder {
    /** 缺省空间。 */
    public func registerFact<T>(schema: FactSchema<T>): RuleSetBuilder
    /** 指定空间；空间不存在时自动创建，标记为"由注册隐式声明"。 */
    public func registerFact<T>(space: String, schema: FactSchema<T>): RuleSetBuilder
    /** 显式声明一个空空间，用于后续规则引用。 */
    public func factSpace(id: String): RuleSetBuilder
}
```

### 6.5 共享与独立

| 声明方式 | 效果 |
|---|---|
| 多条规则 `.facts("orders")` | 共享同一 `FactSpace`：事实互通、网络共享、互相可见副作用 |
| 各规则 `.facts("a")` / `.facts("b")` | 完全隔离：事实、网络、索引、激活互不影响 |
| 未声明 | 归入 `"default"`，等价于显式 `.facts("default")` |
| 决策表 `.factSpace("orders")` | 该表编译出的全部规则归入 `"orders"` |

**共享的语义**：

1. 同一空间内的规则看到的是同一批事实；
2. 一条规则的 `assert` / `retract` 对同空间的其他规则立即生效（按传播顺序）；
3. 同一空间的规则共享 Rete 网络分片，alpha 节点跨规则复用；
4. 共享是**显式**的：没有隐式跨空间可见性。

**共享的风险**：

| 风险 | 说明 | 缓解 |
|---|---|---|
| 副作用耦合 | A 规则 retract 了 B 规则依赖的事实，B 的激活被撤回 | 共享空间的规则应视为同一业务单元；只读改写用 `FactBaseView(Isolated)` 试算后再提交 |
| 顺序不确定 | 同空间内多规则同时满足时执行顺序由议程决定 | 用 `salience` 显式排序 |
| 调试困难 | 一个事实变更触发多条规则 | 开启 `TraceLevel.Activations` 记录来源规则 |

### 6.6 跨库约束

规则是**单库**的：一条规则的所有 `Pattern` 必须属于同一个 `FactSpace`。

| 情况 | 处理 |
|---|---|
| 同一规则内两个 `Pattern` 引用不同空间 | 构建期抛 `CROSS_SPACE_JOIN` |
| `JoinConstraint` 两侧绑定跨空间 | 同上 |
| 决策表的多行引用不同空间 | 不允许；一张表只能有一个 `factSpace` |
| 需要跨库数据 | 用 `ResolveTask` 把事实复制到目标空间，或在宿主 `Action` 里读另一空间后 `assert` 过来 |

不提供"跨空间 join"是有意为之：跨库 join 会让网络分片失效、撤销语义变复杂（两个库的生命周期不同），收益不足以抵消复杂度。需要关联两库数据时，把关联结果物化成目标库的事实。

### 6.7 会话隔离

隔离维度从一维变为二维：`(session, factSpace)`。

```
RuleEngine
├── FactSpace("orders")  ── session A → FactBase("orders", A)
│                           session B → FactBase("orders", B)
└── FactSpace("users")   ── session A → FactBase("users", A)
                            session B → FactBase("users", B)
```

```cangjie
/**
 * 会话 + 空间级事实视图。
 * 同一 (space, session) 返回同一视图；不同组合互不可见。
 */
public class FactBaseView {
    public prop space: String
    public prop session: String
    public func assert(fact: Fact): FactHandle
    public func retract(handle: FactHandle): Bool
    public func get(handle: FactHandle): ?Fact
    public func scan(typeTag: String): Array<FactHandle>
    public func fork(childSession: String): FactBaseView
    public func commitToParent(): Unit
}
```

隔离级别（同一空间内）：

| 级别 | 行为 |
|---|---|
| `Isolated`（默认） | 子视图事实对父不可见，`commitToParent` 时合并 |
| `Shared` | 直接读写父视图，用于规则流内共享同一批事实 |

规则流默认用 `Shared`：`FlowContext.facts(space)` 返回同一 `FactBaseView`。

### 6.8 生命周期

```
RuleSet.build()
  ├─ FactSpace("default") ─ 空
  ├─ FactSpace("orders")  ─ 空
  └─ ReteNetwork 按 space 分片

engine.session("s1")
  ├─ FactBase("default", "s1")
  ├─ FactBase("orders",  "s1")
  └─ Agenda("s1")          ← 跨空间统一排序

assert ──▶ bucket ──▶ AlphaMemory（片内索引）──▶ Beta 传播 ──▶ Agenda
retract ◀── 引用计数归零 ◀── Beta 撤回 ◀── Activation 撤回
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
| 规则声明的 `factSpace` 已存在 | `UNKNOWN_FACT_SPACE` |
| 规则的每个 `Pattern.typeTag` 已在该规则的 `factSpace` 注册 | `UNKNOWN_TYPE` |
| 同一规则的所有 `Pattern` 属于同一 `factSpace` | `CROSS_SPACE_JOIN` |
| 约束的每个 `field` 在该类型的字段声明中 | `UNKNOWN_FIELD` |
| 算子与字段的静态类型兼容（可静态判定时） | `TYPE_MISMATCH` |
| `JoinConstraint` 两侧字段都存在且同空间 | `UNKNOWN_FIELD` / `CROSS_SPACE_JOIN` |
| 决策表的 `when.<field>` 全部可解析 | `TABLE_INVALID` |
| 同一 `(factSpace, typeTag)` 未被不一致的 schema 重复注册 | `DUPLICATE_TYPE` |
| 至少存在一个 `FactSpace` | `EMPTY_FACT_SPACE_SET` |

校验失败在构建期抛出，规则集进入 `Invalid` 状态，不得启动。

校验通过后 `FactSpaceRegistry.freeze()`：空间集合、类型描述、字段声明全部冻结，运行期只读。运行期新增空间一律抛 `NETWORK_FROZEN`。
