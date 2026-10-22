# Spec Delta

## ADDED Requirements

### Requirement: 常量键的规范化

常量注册表与运行期句柄表 SHALL 使用**同一份**规范键实现：`Int64 → i:<值>`、`Float64 → f:<位模式>`、`String → s:<值>`、`Decimal → d:<规范化文本>`、`DateTime → t:<纳秒>`、`Duration → u:<纳秒>`、`Range → r:<start>|<end>|<step>|<isClosed>`、`Regex → x:<pattern>|<flags>`、List/Map → 递归 `l[...]` / `m[...]`。

同值必同键、异值必异键；拼装期注册的常量键 SHALL 在运行期 `Map` 查询中命中。规范键 SHALL NOT 因一侧新增常量类型而单边漂移——新增类型必须同时进入该单点实现。

#### Scenario: 非字符串标量键命中

- **WHEN** 以 Float64 / Decimal / DateTime / Duration / Range / Regex 常量作 `Map` 键，在字节码世界里按同值查询
- **THEN** 全部命中，返回注册时写入的值

#### Scenario: 同值同键

- **WHEN** 同一 `Decimal` 以不同书写形式（如 `1.0` 与 `1.00`，若规范化后等值）分别作键
- **THEN** 得到同一规范键；规范化后不等值的两个值必须得到不同键

#### Scenario: 既有键零回归

- **WHEN** 用 Int64 与 String 常量作键
- **THEN** 行为与 M1/M2 一致，键文本逐字不变
