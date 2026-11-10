# Spec Delta

## ADDED Requirements

### Requirement: 差分火焰节点

`DifferentialFlameChart` MUST 为每个节点绘制一个 `class="diff-flame-node"` 矩形，宽度 MUST 按 `value2 / 根节点 value2` 分配，子节点 MUST 从父节点左端依次排列。

#### Scenario: 六个节点

- **WHEN** `nodes` 有 6 个节点
- **THEN** 输出 6 个 `diff-flame-node`

#### Scenario: 标签

- **WHEN** 节点 `name` 为 main
- **THEN** SVG 中包含 `diff-flame-label` 文本 main

### Requirement: 差分颜色

`differentialColor` MUST 在 `delta` 为最大正差值时返回增加色，为最大负差值时返回减少色，为 0 时返回中性色；默认增加色为红、减少色为蓝。

#### Scenario: 增加

- **WHEN** `delta` 为 10 且最大绝对差值为 10
- **THEN** 返回增加色 `#e53935`

#### Scenario: 减少

- **WHEN** `delta` 为 −10 且最大绝对差值为 10
- **THEN** 返回减少色 `#4a90d9`

#### Scenario: 无变化

- **WHEN** `delta` 为 0
- **THEN** 返回中性色

### Requirement: 差分校验

`value1` / `value2` MUST 为非负数字且至少一个大于 0；父节点的每个值 MUST 不小于对应子节点值之和；`nodes` MUST 非空、id 唯一、恰好一个根、`parent` 指向存在的节点。

#### Scenario: 缺少 value2

- **WHEN** 某节点只有 `value1`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 子节点和超过父节点

- **WHEN** 父节点 `value2` 为 100、子节点 `value2` 为 150
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
