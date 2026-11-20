# Spec Delta

## ADDED Requirements

### Requirement: `@DataAssist[compare]` 生成的 `compare` 必须返回真实顺序

`compare` MUST 按字段声明顺序逐个比较，第一个不相等的字段的 `Ordering` 即为返回值；全部字段相等时才返回 `EQ`。MUST NOT 对任何输入都返回 `EQ`。

#### Scenario: 不同字段值

- **WHEN** 被 `@DataAssist[compare]` 修饰的类实例 `a` 的首个参与比较字段大于 `b` 的同名字段
- **THEN** `a.compare(b)` 返回 `Ordering.GT`，`b.compare(a)` 返回 `Ordering.LT`

#### Scenario: 全部字段相等

- **WHEN** 两个实例的每个参与比较字段都相等
- **THEN** `a.compare(b)` 返回 `Ordering.EQ`

#### Scenario: 前置字段相等时看后续字段

- **WHEN** 首个字段相等、第二个字段不等
- **THEN** 由第二个字段决定返回值（说明逐字段短路生效，而不是只看第一个字段）
