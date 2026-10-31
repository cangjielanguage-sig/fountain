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

### 6.4 M0 spike 实测结论

环境：Linux aarch64（`cjc 1.3.0-alpha.20261023001052`、`cjpm 1.3.0-alpha.08`），2026-10-31。
方法：`@JitBind` 修饰一个与 `DynamicFact` 同签名的探针类（`get(name): ?Any`、`has(name): Bool`），
用 `Compiler.registerType` 登记后逐条编译/调用，记录失败码与消息。探针代码属一次性 spike，未入库。

**① 动态事实的 `get(): ?Any` 不能进 JIT**

| 探针 | 源码 | 结果 |
|---|---|---|
| 1a | `{ f: Fact => f.get("amount") > 200 }` | `SourceCompileException` `TypeMismatch`：`运算两侧类型不兼容: HostObject / Int64` |
| 1b | `{ f: Fact => f.get("amount") != None }` | `SourceCompileException` `NotAssigned`：脚本里 `None` 不是字面量，被当成未赋值的局部变量 |
| 1c | `{ f: Fact => f.has("amount") }` | 正常，`call<Bool>` 返回 `true` |
| 1d | `{ f: Fact => let a: Any = 1; a == 1 }` | `TypeMismatch`：`Any 值上不得做运算 / 比较 / 等值` |
| 1e | `{ f: Fact => let v = f.get("amount"); true }` | 编译通过，**运行期** `JitException(code=99)`（`?Any` 装箱值的解包路径未实现） |
| 1f | `{ f: Fact => (f.get("amount") as Int64) > 200 }` | `TypeMismatch`：`as Int64` 的左面静态类型是 `?`，类型不相容 |

结论：`?Any` 返回值一律映射为 `HostObject`，既不能比较、不能取 `as`、也不能承接给局部变量；
动态事实的脚本条件**在本期无任何 JIT 可行写法**。`has()` 这类 `Bool` 方法可用，但缺少取值能力就
无法表达阈值判断。

**② `call<T>` 的 `T` 必须精确等于返回类型，`Option` 不可作返回类型**

| 探针 | 场景 | 结果 |
|---|---|---|
| 2a | `{ b: Bool => b }` + `call<Bool>` | 正常返回 `true` |
| 2b | 同上 + `call<Any>` | `JitException`：`T 与返回类型不符（§8.2 第 5 步）` |
| 2c | 同上 + `call<Int64>` | 同上 |
| 2d | `{ b: Bool => Some(b) }` | `NotAssigned`：`Some` / `None` 均非脚本字面量 ⇒ `Option` 无法构造 |
| 2f/2g/2h | `{ b: Bool => let a: Any = b; a }` | 只能 `call<Any>`；`call<Bool>` 报 `T 与返回类型不符` |

结论：谓词单元必须**恰好**返回 `Bool`，宿主用 `call<Bool>` 取回；不能用 `Any` 承接再转 Bool，
也不能用 `Option` 表达"无结果"。因此 `JitExpression.eval` 的签名只能是 `Bool`，失败语义走异常/三值
外层包装，而不是靠返回值表达。

**③ `@JitBind` 只覆盖实例成员与构造器，静态成员不参与脚本语法**

| 探针 | 源码 | 结果 |
|---|---|---|
| 3a | `{ => Order.of(7).total() }` | `NotAssigned`：`Order` 被当成局部变量 ⇒ 静态函数调用不可解析 |
| 3b | `{ => Order.ZERO }` | `NotAssigned`：静态字段同上 |
| 3c | `{ => Order(7).total() }` | 正常，返回 `7`（构造器 + 实例方法都通） |
| 3e | `{ o: Order => o.amount }` | 正常，返回 `42`（实例字段） |
| 3f | `{ o: Order => o.total() }` | 正常，返回 `42`（实例方法） |
| 3g | 预定义函数返回对象后链式取成员 `spikeOrderOf(7).total()` | `NotImpl`：`成员调用属 M2` |
| 3h | 预定义函数单独返回对象 `spikeOrderOf(7)` | 正常，`call<Order>` 取回对象 |
| 3i | 预定义函数返回标量 `spikePlus(x)` | 正常 |

结论：脚本里能用的只有**模式绑定的形参**（实例字段/方法）、字面量、运算符与已注册的预定义函数；
不能调用 `Order.of(...)`、读静态常量，也不能对预定义函数的返回值继续取成员。规则 DSL 因此不承诺
"脚本内构造对象"，**构建期校验**必须拦住这类写法（`SCRIPT_COMPILE`），而不是留到运行期。

**对 `ExpressionMode` 的影响**

- 默认值维持 `JitPreferred`（`doc/03` §7）：强类型事实的脚本条件编译成功即可直接用 JIT。
- 动态事实（`DynamicFact`）的脚本条件**无条件**走内置解释器：不是"失败后回退"，而是构建期就按
  绑定类型决定，并记一条 `WARN`（含规则 id、字段名）。这样避免同一规则在不同机器上因后端差异
  静默换路径。
- 1e 的 `code=99` 只在 aarch64 后端观测到；1a/1f/2b/2c/3a/3b 都是**前端**类型检查错误，
  与后端无关。动态事实走解释器的决定不依赖 1e，故即便该后端缺陷被修复也不改变默认策略。

### 6.5 一元 `!` 的 AArch64 编码缺陷（已修复）

**现象**：`f_jit` 的 JIT 路径把 `!(n < 50)` 在 `n = 49` 上算成 `true`，内置解释器算成 `false`（正确）。

```cangjie
let f = c.compile("{ n: Int64 => !(n < 50) }")
f.call<Bool>([Int64(49)])     // 修复前 JIT: true（错误）；修复后: false
```

**根因**（不是优先级，而是机器码编码错误）：`A64Lower` 的 `NOT_B`（`0x5E`）用裸字面量
`0xD2400009`，位域解码后 `Rn = 00000`，实际是 `EOR X9, X0, #1`，而注释写的是 `EOR X9, X9, #1`
（正确值 `0xD2400129`）。序言 `movReg(19, 0)` 之后 `x0` 仍是 ctx 指针且函数体不写它，于是
`X9 = ctx | 1` 恒非零；`CallMarshal` 按 `cell != 0` 解包 Bool，任何 `!expr` 都恒为 `true`
（含 `!flag`、`!!x`、`s !~ "pat"`）。

**修复**（`fix-jit-unary-not`，已合入 `sts/1.3.x`）：

| 改动 | 内容 |
|---|---|
| `A64Emitter.eorImm1(rd, rn)` | `0xD2400000 \| rn << 5 \| rd`，`eorImm1(9,9)` = `0xD2400129` |
| `A64Lower` 0x5E | 改调 `eorImm1(9, 9)`，删除裸字面量 |
| `Lowerer.lowerUnary` 的 `Bang` | 按操作数类型分派：`Bool → NOT_B`、`Int64 → BNOT_I`、其余 `TYPE_MISMATCH` |

**f_rule 侧的变化**：原先「含一元 `!` 一律降级内置解释器」的绕过（`hasUnaryNot`）已删除。
含 `!` 的条件重新走 JIT；用 `JitExpression.usesJit` 可观测实际路径。

**回归判据**：

- `InterpreterVsJit_test` 的 `!(o.amount < 50)` 在 `JitPreferred` 与 `Interpreted` 下逐条一致；
- `JitExpressionMode_test` 断言含 `!` 的条件 `usesJit == true`，且 `n = 49` 求值为 `false`；
- 动态事实仍强制走解释器，与本次修复无关。

## 7. 内置解释器（降级路径）

当 f_jit 不可用（平台不支持、类型未登记、`Option`/`Any` 限制）时，`JitExpression` 降级为内置解释器。内置解释器只支持受限语法，覆盖面小于 f_jit：

> 动态事实（`DynamicFact.get(): ?Any`）**总是**走解释器，不依赖"编译失败再回退"——
> 原因见 §6.4 ①：JIT 侧的 `?Any` 没有任何可用写法，靠失败回退会在不同后端上得到不同路径。

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
