# Spec Delta — f-rule-condition

## ADDED Requirements

### Requirement: 算子语义

系统 SHALL 提供 `Operator` 枚举：`Eq / Ne / Gt / Ge / Lt / Le / Contains / StartsWith / EndsWith /
In / NotIn / IsNull / NotNull / Matches / Between`，语义与可索引性 SHALL 等于
`doc/03-condition-expression.md` §2 的表格。

`Matches` SHALL 走 `f_regex`（`String.regex()` + `Regex.matches`）做整串匹配；`Between` SHALL 是闭区间；
`In` 的右值 SHALL 是 `Array` 或 `Set`，空集合恒为 false。

#### Scenario: 范围算子

- **WHEN** 字段 `amount=200`，约束 `Between [200, 300]`
- **THEN** 判定为 true（闭区间）

#### Scenario: In 空集合

- **WHEN** 右值为空数组
- **THEN** 判定为 false，不抛错

#### Scenario: 正则

- **WHEN** 字段 `code="AB12"`，约束 `Matches "^[A-Z]+$"`
- **THEN** 判定为 false（整串匹配）

### Requirement: 三值逻辑

条件求值 SHALL 采用三值逻辑：任一侧为 `None` → `Unknown`；`And` 任一 `False` 即 `False`，否则有
`Unknown` 即 `Unknown`；`Or` 任一 `True` 即 `True`，否则有 `Unknown` 即 `Unknown`；`Not Unknown`
仍为 `Unknown`。

规则匹配 SHALL 只接受 `True`；`Unknown` 与 `False` 等价，均不产生激活。`IsNull` / `NotNull` SHALL 是
唯一能显式判定字段缺失的算子。

#### Scenario: 缺失字段不满足

- **WHEN** `DynamicFact` 没有 `amount` 字段，约束 `amount Gt 100`
- **THEN** 结果为 `Unknown`，不产生激活

#### Scenario: IsNull 命中缺失

- **WHEN** 同一事实使用 `IsNull`
- **THEN** 结果为 `True`

### Requirement: 操作数、约束与模式

`Operand` SHALL 支持 `Const(Any)`、`Field(String)`、`Bind(binding, field)`；`Bind` SHALL 只允许出现在
`JoinConstraint` 中，`Constraint` 的右操作数只允许 `Const` 或同事实的 `Field`。

`Constraint(field, op, right)` SHALL 校验 `field` 已在所属类型的字段声明中，否则构建期抛
`UNKNOWN_FIELD`。`Pattern(typeTag, binding)` SHALL 要求 `binding` 在同一规则内唯一；
`constrain(field, op, value)`、`constrainField(field, op, rightField)`、`constrainNot`、`Pattern.any` SHALL 可用。
`where` 是仓颉关键字，故条件方法统一命名为 `constrain*`。

约束顺序 SHALL 不影响语义；`NetworkBuilder` MAY 按"可索引性 + 选择率"重排执行顺序。

#### Scenario: 约束重排等价

- **WHEN** 同一组约束以不同顺序书写
- **THEN** 匹配集合完全相同

#### Scenario: 绑定名重复

- **WHEN** 一条规则内两个 `Pattern` 使用同一 `binding`
- **THEN** 构建期抛 `RuleException(ILLEGAL_STATE)`

### Requirement: 条件树与展开限制

`ConditionExpr` SHALL 支持 `And` / `Or` / `Not` / `Leaf` / `Join` / `Script`。

`Or` 的分支跨不同 `typeTag` 时 SHALL 在构建期展开为多条规则，展开后的规则 id 加后缀 `#1`、`#2`；
`Not` SHALL 只包裹单事实约束，包裹 join 时 SHALL 抛 `RuleException(ILLEGAL_STATE)`（否定模式留待后续）；
嵌套深度 SHALL 上限 32，超出抛 `RuleException(TABLE_INVALID)`。

#### Scenario: Or 展开

- **WHEN** 一条规则的条件是 `typeTag=A 的约束 OR typeTag=B 的约束`
- **THEN** `RuleSet.rules` 出现 `<id>#1` 与 `<id>#2` 两条规则，各自单类型

#### Scenario: 深度上限

- **WHEN** 条件树嵌套 33 层
- **THEN** 构建期抛 `RuleException(TABLE_INVALID)`

### Requirement: 表达式条件与求值模式

`JitExpression` SHALL 支持两种构造：

1. `of(source)`：`source` 是完整 lambda 字面量（以 `{` 开头，形参带类型），直接交 `f_jit` 编译；
2. `ofExpression(source, bindings)`：`source` 是裸布尔表达式，由 `f_rule` 用绑定名与其已登记的宿主类型
   名拼成 `{ b1: N1, b2: N2 => source }` 后编译。

`RuleSetBuilder.expressionMode(mode)` SHALL 支持 `JitPreferred`（默认）与 `Interpreted`。
`Interpreted` SHALL 完全绕开 `f_jit`，使用内置解释器；解释器 SHALL 支持
`&& || ! ()` 比较、字段访问、字面量与白名单函数
（`lower/upper/trim/length/abs/round/now/dayOfWeek/contains/startsWith/endsWith`）。

`JitPreferred` 下语法或类型错误 SHALL 抛 `RuleException(SCRIPT_COMPILE)`，**不得**静默降级；
仅当绑定集合包含 `DynamicFact`（`f_jit` 无法表达 `get(): ?Any`）时 SHALL 该条件整体走内置解释器，
并在构建期记一次 WARN。

`RuleSet.build()` SHALL 校验每个 `Script` 的形参都能在模式绑定中找到，缺失抛
`RuleException(SCRIPT_BINDING_MISSING)`。

#### Scenario: 动态事实走解释器

- **WHEN** 规则绑定 `DynamicFact` 且 `expressionMode = JitPreferred`，条件为 `amount > 200`
- **THEN** 构建成功，该条件由解释器求值，日志含一条 WARN

#### Scenario: 语法错误不降级

- **WHEN** `expressionMode = JitPreferred` 且表达式有语法错误
- **THEN** 构建期抛 `RuleException(SCRIPT_COMPILE)`，不产生可运行规则集

#### Scenario: 形参不齐

- **WHEN** 脚本条件声明了绑定 `u`，但规则里没有绑定名为 `u` 的 `Pattern`
- **THEN** 构建期抛 `RuleException(SCRIPT_BINDING_MISSING)`

### Requirement: 求值失败的运行期语义

表达式运行期异常（除零、越界、类型不符）SHALL 视为 `Unknown`，不产生激活，记录 WARN（含规则 id、
session、site）；同一规则连续失败 100 次后 SHALL 禁用该规则并记 ERROR。

单次求值 SHALL 受 `EngineOptions.expressionTimeout`（默认 50ms）约束，超时视为 `Unknown`；
异常 SHALL NOT 穿透到 `f_egraph` 的事件循环。

#### Scenario: 除零不中断

- **WHEN** 动作前某次表达式求值触发除零
- **THEN** 该次结果为 `Unknown`，`fire()` 继续执行其余激活

### Requirement: 类型检查时机

常量与字段的静态类型在 `FactSchema` 已声明时 SHALL 在构建期校验，不兼容抛 `TYPE_MISMATCH`；
字段类型未知（动态事实）时 SHALL 在运行期首次求值失败抛 `TYPE_MISMATCH` 并禁用该规则；
`JitExpression` 的类型错误 SHALL 在 `f_jit` 编译期暴露，包装为 `SCRIPT_COMPILE`。

#### Scenario: 静态不兼容

- **WHEN** `FactSchema` 把 `amount` 声明为 `Number`，约束写成 `amount Matches "x"`
- **THEN** 构建期抛 `RuleException(TYPE_MISMATCH)`
