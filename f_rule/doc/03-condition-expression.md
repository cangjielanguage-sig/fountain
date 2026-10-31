# 03 条件与表达式

## 1. 分层

```
ConditionExpr（布尔组合）
├── And / Or / Not
└── Leaf
    ├── Constraint      单事实字段 vs 常量
    ├── JoinConstraint  两个模式的字段互比
    └── JitExpression   f_jit 编译的任意布尔表达式
```

`Constraint` 与 `JoinConstraint` 走内置求值（快、可索引）；`JitExpression` 走 `f_jit`（灵活、慢一个数量级）。决策表默认只生成前两者。

## 2. 算子

```cangjie
public enum Operator <: ToString & Hashable & Equatable<Operator> {
    | Eq | Ne
    | Gt | Ge | Lt | Le
    | Contains | StartsWith | EndsWith
    | In | NotIn
    | IsNull | NotNull
    | Matches
    | Between
    public func toString(): String
    public func hashCode(): Int64
    public operator func ==(other: Operator): Bool
}
```

| 算子 | 左值 | 右值 | 语义 | 可索引 |
|---|---|---|---|---|
| `Eq` | 任意标量 | 同域标量 | 归一后相等 | 是（hash） |
| `Ne` | 任意标量 | 同域标量 | 归一后不等 | 否 |
| `Gt` `Ge` `Lt` `Le` | 数值/字符串/时间 | 同域 | 同域比较 | 是（有序） |
| `Contains` | `String` / `Array` / `Set` | 同元素类型 | 子串或成员包含 | 否 |
| `StartsWith` `EndsWith` | `String` | `String` | 前后缀 | 否 |
| `In` | 标量 | `Array` / `Set` | 左值 ∈ 右集合 | 是（集合展开为多值索引） |
| `NotIn` | 标量 | `Array` / `Set` | 左值 ∉ 右集合 | 否 |
| `IsNull` | 任意 | 无 | `get` 返回 None | 是（空桶） |
| `NotNull` | 任意 | 无 | `get` 返回 Some | 是（非空桶） |
| `Matches` | `String` | `String` 正则 | `f_regex` 全匹配 | 否 |
| `Between` | 数值/时间 | `Array` 两元素 | 闭区间 | 是（区间索引） |

### 2.1 NULL 语义

采用 **三值逻辑**：

- 任一侧为 None → 结果为 `Unknown`；
- `And`：任一 `False` → `False`；否则有 `Unknown` → `Unknown`；全 `True` → `True`；
- `Or`：任一 `True` → `True`；否则有 `Unknown` → `Unknown`；全 `False` → `False`；
- `Not Unknown` = `Unknown`；
- 规则匹配只接受 `True`，`Unknown` 与 `False` 等价（不产生激活）。

这与 SQL 一致，避免"字段缺失"被误判为满足条件。`IsNull` / `NotNull` 是唯一能显式判定缺失的算子。

### 2.2 类型检查时机

| 情况 | 时机 |
|---|---|
| 常量与字段的静态类型已知（`FactSchema` 声明了类型） | 构建期 |
| 字段类型未知（动态事实） | 运行期首次求值，失败抛 `TYPE_MISMATCH` 并禁用该规则 |
| `JitExpression` | `f_jit` 编译期 |

`FactSchema.field` 可选择性声明类型：

```cangjie
public func field(name: String, type: FieldType, getter: (T) -> Any): FactSchema<T>
```

`FieldType` 为 `Scalar | Number | Text | Bool | Time | List | Any`。声明后构建期可做更严格的校验；不声明则按 `Any` 处理。

## 3. 操作数

```cangjie
public enum Operand {
    /** 常量 */
    | Const(Any)
    /** 同一模式内的字段 */
    | Field(String)
    /** 前序模式的绑定字段，写法 "$o.amount" */
    | Bind(String, String)
}
```

`Bind` 只能出现在 `JoinConstraint` 中；`Constraint` 的右操作数只允许 `Const` 或同事实的 `Field`。

## 4. 模式与约束

```cangjie
public class Constraint {
    public init(field: String, op: Operator, right!: Operand)
    public let field: String
    public let op: Operator
    public let right: Operand
}

public class Pattern {
    /**
     * @param typeTag 事实类型
     * @param binding 绑定名，在同一规则内唯一，动作里用它取值
     */
    public init(typeTag: String, binding: String)
    public func where(field: String, op: Operator, value: Any): Pattern
    public func where(field: String, op: Operator, rightField: String): Pattern
    public prop typeTag: String
    public prop binding: String
    public prop constraints: Array<Constraint>
}

public class JoinConstraint {
    public init(leftBinding: String, leftField: String, op: Operator,
                rightBinding: String, rightField: String)
}
```

约束顺序无关：`NetworkBuilder` 会按"可索引性 + 选择率"重排，选择率高的先测。选择率未知时按 `Eq > In > 范围 > 非索引` 排序。

## 5. 条件树

```cangjie
public enum ConditionExpr {
    | And(Array<ConditionExpr>)
    | Or(Array<ConditionExpr>)
    | Not(ConditionExpr)
    | Leaf(Constraint)
    | Join(JoinConstraint)
    | Script(JitExpression)
}
```

限制：

- `Or` 的分支如果跨越不同 `typeTag`，不能进入同一 alpha 链，会退化为多条规则（构建期展开，规则 id 加后缀 `#1`、`#2`）；
- `Not` 只允许包裹单事实约束；包裹 join 需要改为否定模式（`NotPattern`，M2 之后支持）；
- 嵌套深度上限 32，超出抛 `TABLE_INVALID`（防止构造期栈溢出）。

## 6. f_jit 表达式

```cangjie
public class JitExpression {
    /** 从源码编译，结果进入 RuleSet 级 CompileCache。 */
    public static func of(source: String, compiler!: Compiler): JitExpression

    /**
     * 求值。
     * @param bindings 绑定名 → 事实实例，顺序必须与源码形参一致
     */
    public func eval(bindings: Bindings): Bool

    /** 源码形参名，构建期从签名解析，用于校验绑定是否齐备。 */
    public prop parameters: Array<String>
    public prop source: String
}
```

### 6.1 编译缓存

`f_jit` 自带 `CompileCache`，键为源码字符串。`f_rule` 额外维护一层 `Map<(source, 形参签名), JitExpression>`，避免重复解析签名。规则集卸载时清空。

### 6.2 求值失败

| 失败 | 处理 |
|---|---|
| 编译错误 | 构建期抛 `RuleException(SCRIPT_COMPILE)`，携带 f_jit 的 `site` 与 `report` |
| 运行期异常（除零、越界） | 该次求值视为 `Unknown`，记录 `WARN` 日志（含规则 id、session、site）；同一规则连续失败 100 次后禁用并记 `ERROR` |
| 超时 | 通过 `CallContext(deadline:)` 中断，视为 `Unknown`；默认单次求值上限 50ms |

不允许表达式抛出的异常穿透到事件循环：`f_egraph` 的 `TaskExecutor` 会把异常包装成错误事件，导致整个流程终止。

### 6.3 类型注册

`JitExpression` 依赖 `Compiler` 已登记全部参与类型：

```cangjie
@JitBind
public class Order { ... }

let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
compiler.registerType<Order>()
compiler.registerType<DynamicFact>()
```

`RuleSet.build()` 会校验每条 `Script` 条件的 `parameters` 都能在模式绑定中找到；缺失抛 `SCRIPT_BINDING_MISSING`。

## 7. 内置解释器（降级路径）

当 f_jit 不可用（平台不支持、类型未登记、`Option`/`Any` 限制）时，`JitExpression` 降级为内置解释器。内置解释器只支持受限语法，覆盖面小于 f_jit：

```
expr   := or
or     := and ( "||" and )*
and    := unary ( "&&" unary )*
unary  := "!" unary | primary
primary:= "(" expr ")" | comparison
comp   := term ( op term )?
term   := number | string | bool | null | field | call
field  := ident ( "." ident )*
call   := ident "(" args ")"
```

支持的函数白名单：`lower`、`upper`、`trim`、`length`、`abs`、`round`、`now`、`dayOfWeek`、`contains`、`startsWith`、`endsWith`。

降级是**显式**的，不在运行期静默切换：

```cangjie
ruleSet.expressionMode(ExpressionMode.Interpreted)   // 全部走内置
ruleSet.expressionMode(ExpressionMode.JitPreferred)  // 默认：能编译就编译，失败回退
```

`JitPreferred` 下编译失败仍按 §6.2 抛错；只有 `Interpreted` 才完全绕开 f_jit。这样避免"同一规则在不同环境行为不同"。

## 8. 与决策表的关系

决策表的单元格只生成 `Constraint`，不生成 `JitExpression`：

```
when.order.amount  | >=200
```

→ `Constraint("amount", Ge, Operand.Const(200))`

需要复杂逻辑时，决策表提供 `expr` 列，单元格写表达式源码，生成 `JitExpression`。两种列可以混用。

## 9. 求值顺序与短路

一条规则内：

1. 先跑 alpha 链（单事实约束），失败即丢弃该事实；
2. 再跑 beta join（按索引探测）；
3. 最后跑 `Script` 条件（最贵，且只在前面全部通过后执行）。

`And` 内部按上述代价升序；`Or` 不重排（保持用户书写顺序，便于解释）。

## 10. 可解释性

每次匹配可开启追踪：

```cangjie
ruleSet.trace(level: TraceLevel.Constraints)
```

输出结构：

```json
{
  "rule": "R1",
  "session": "abc",
  "bindings": { "o": 1001 },
  "constraints": [
    { "field": "amount", "op": "Ge", "right": 200, "result": true },
    { "field": "level", "op": "Ge", "right": 3, "result": false }
  ]
}
```

追踪只在显式开启时产生，默认关闭以免影响性能。
