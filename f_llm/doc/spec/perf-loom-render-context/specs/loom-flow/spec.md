# Spec Delta

## ADDED Requirements

### Requirement: 模板替换是单遍扫描且不占全局锁

`LoomHostApi.render` MUST 在锁内只读取快照，替换在锁外完成；替换复杂度 MUST 是 `O(模板长度)`，
MUST NOT 对每个已产出步骤全串扫描一次。

#### Scenario: 多步输出一次替换

- **WHEN** 已记录 `a` 与 `b` 的输出，模板为 `{a.output}|{b.output}`
- **THEN** 两个占位符都被替换，且只扫描一遍模板

#### Scenario: 未知占位符保留

- **WHEN** 模板含 `{c.output}` 但 `c` 还没产出
- **THEN** 原样保留 `{c.output}`

#### Scenario: 事件无数据

- **WHEN** 起始事件的数据为空
- **THEN** `{start.output}` 原样保留（不替换成空串）

#### Scenario: JSON 中的嵌套花括号

- **WHEN** 模板是 `{"k":"{a.output}"}`
- **THEN** 结果是 `{"k":"<a 的输出>"}`，外层 JSON 花括号不受影响

### Requirement: 执行期快照有上限

`LoomContextLog` MUST 限制单次执行的轮数上限（`MAX_TURNS = 200`）；超出后 MUST 丢弃最旧的轮次，保留最近的。

#### Scenario: 超过上限

- **WHEN** 一次执行记录了 230 轮
- **THEN** `snapshot()` 返回 200 轮，且最后一条是第 230 轮
