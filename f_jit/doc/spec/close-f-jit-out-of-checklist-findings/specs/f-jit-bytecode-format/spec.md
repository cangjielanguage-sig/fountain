## MODIFIED Requirements

### Requirement: 常量键的规范化

常量注册表与运行期句柄表 SHALL 使用**同一份**规范键实现：`Int64 → i:<值>`、`String → s:<值>`、`Decimal → d:<去尾零文本>`、`DateTime → t:<纳秒>`、`Duration → u:<纳秒>`、`Range → r:<start>|<end>|<step>|<isClosed>`、`Regex → x:<pattern>|<flags>`、List/Map → 递归 `l[...]` / `m[...]`。

**值型键（Int64 / Float64）SHALL 一律取裸 cell 形态 `i:<64 位模式>`**：同一个 `Float64` 无论以裸 cell 还是 `Any` 盒承载，得到的键文本 SHALL 相同；SHALL NOT 为 Float64 另立 `f:` 之类的前缀。同值必同键、异值必异键；拼装期注册的常量键 SHALL 在运行期查询中命中。

#### Scenario: 非字符串标量键命中

- **WHEN** 以 Float64 / Decimal / DateTime / Duration / Range / Regex 常量作 `Map` 键，在字节码世界里按同值查询
- **THEN** 全部命中，返回注册时写入的值

#### Scenario: 承载形态无关

- **WHEN** 同一个 `Float64` 分别以裸 cell 与 `Any` 盒（经 `any_box`）作 `Map` 键
- **THEN** 两者得到同一规范键，且都能命中同一常量条目

#### Scenario: 同值同键

- **WHEN** 同一 `Decimal` 以不同书写形式（如 `1.5` 与 `1.50`）分别作键
- **THEN** 得到同一规范键；规范化后不等值的两个值必须得到不同键

#### Scenario: 既有键零回归

- **WHEN** 用 Int64 与 String 常量作键
- **THEN** 行为与 M1/M2 一致，键文本逐字不变
