# Spec Delta

## ADDED Requirements

### Requirement: 正则字面量的 flags 保真

词法 SHALL 把正则字面量的 flags 原样带进 token，编译期 SHALL 以该 flags 构造正则：`i`（忽略大小写）、`m`（多行）、`s`（单行）逐个生效，未给出的 flag SHALL 为 0。

#### Scenario: i flag 生效

- **WHEN** 编译并执行 `r"AbC"i` 匹配 `"abc"`，以及 `r"AbC"` 匹配 `"abc"`
- **THEN** 前者命中、后者不命中

#### Scenario: m / s flag 生效

- **WHEN** 分别用 `m` 与 `s` 各写一个只在对应模式下命中的 pattern
- **THEN** 对应的匹配结果与仓颉 `Regex` 在同 flags 下的结果一致，token 的 flags 位逐位正确

### Requirement: `else if` 链的语法

`if` 语句的 `else` 分支 SHALL 接受两种后继：`{...}` 块语句，或另一个 `if` 语句（`else if`）。`else if` 链 SHALL 与等价的嵌套 `if` 逐位同义。

#### Scenario: 三臂 else if

- **WHEN** 编译并执行 `if (a) {...} else if (b) {...} else {...}`
- **THEN** 三个分支各自可达，结果与嵌套写法相同

#### Scenario: else 后接非块表达式

- **WHEN** 写 `else x + 1`（无块、非 if）
- **THEN** 报语法错误，不静默接受

### Requirement: 表达式降低的求值顺序与静态类型

表达式的求值与静态类型 SHALL 满足：

1. **尾部自调用实参**：全部实参 SHALL 先求值到临时槽，再按序写入形参槽；实参 SHALL 左→右求值，SHALL NOT 因形参槽复用而互相覆盖。
2. **立即调用**：调用返回值类型 SHALL 取被调闭包的真实返回类型；闭包签名未知时 SHALL 为 `NONE` 并沿用既有诊断，SHALL NOT 硬编码 `I64`。
3. **期望类型转换**：`lowerExprAs` SHALL 对无法转换的「期望 → 实际」组合报编译错误（消息含两侧类型名）；已定义的转换（`I64 → F64`、JSON 谱系收窄等）SHALL 保持既有行为。

#### Scenario: 实参反转不自覆盖

- **WHEN** 执行 `fn rec(a: Int64, b: Int64) { ... rec(b, a) }`，其中 `a` 与 `b` 取不同值
- **THEN** 递归调用的实参与交换前的值一一对应，与手写循环结果一致

#### Scenario: IIFE 返回 String

- **WHEN** 执行 `let s = (fn() { "abc" })()` 并继续求 `s.size`
- **THEN** 静态类型为 String，结果为 3；返回 `Any`、JSON、Unit 的 IIFE 各自类型正确

#### Scenario: 不可转换组合被拒

- **WHEN** 在需要 `String` 的位置给 `Int64`，在需要 `Int64` 的位置给 `Bool`，在需要值型的位置给 14
- **THEN** 均为编译错误，消息包含「期望 → 实际」

### Requirement: 实例方法的重载解析

类注册表的成员查询 SHALL 支持同名重载：按「实参个数 → 逐参静态类型精确匹配 → 子类可上行至父类形参」的顺序选择，唯一命中方可返回；存在多个同样优的候选 SHALL 为编译错误（消息列出候选签名），无命中 SHALL 为既有的「未注册方法」错误。

#### Scenario: 按实参类型选重载

- **WHEN** 类同时注册 `f(Int64)` 与 `f(String)`，分别以 Int64、String 实参调用
- **THEN** 各命中对应重载，行为与其声明一致

#### Scenario: 子类实参上行

- **WHEN** 形参声明为父类 `A`，实参静态类型为 `A` 的子类 `B`
- **THEN** 命中 `f(A)`，不报「未注册方法」

#### Scenario: 多义

- **WHEN** 两个候选在该实参下无法区分
- **THEN** 编译错误，消息列出全部候选

### Requirement: 算术与字符串的组合面

`+` 在两侧（或任一侧）为 String 时 SHALL 走字符串拼接；`-`、`*`、`/`、`%` 在任一侧为 String 时 SHALL 为编译错误（消息含位置），SHALL NOT 退化数值运算。

#### Scenario: 拼接仍有效

- **WHEN** 执行 `"a" + "b"` 与 `"a" + 1`
- **THEN** 结果分别为 `"ab"` 与既有的拼接结果

#### Scenario: 其余运算符被拒

- **WHEN** 写 `"a" - "b"`、`"a" * "b"`、`"a" / "b"`、`"a" % "b"`、`"a" - 1`
- **THEN** 逐个编译错误并给出位置

### Requirement: `Any` 位置的容器装箱

需要 `Any` 的实参位置（`is`/`as` 之外的传参、返回）SHALL 与声明初始化同等地插入装箱：容器字面值整体装箱为盒句柄，元素按 `Any` 盒写入；每次求值 SHALL 只求值一次，SHALL NOT 出现「实参未装箱而直接进盒」的路径。

#### Scenario: `List<Any>` 实参

- **WHEN** 以 `[1, "a"]` 字面值调用 `fn f(xs: List<Any>)`
- **THEN** 盒内可 `any_as(元素, Int64)` 与 `any_as(元素, String)` 分别命中，元素未裸露在盒外

#### Scenario: 整体装箱一次

- **WHEN** 以值型列表调用 `fn g(a: Any)`
- **THEN** 只产生 1 个外层盒，元素不再重复求值（构造性用例计数）
