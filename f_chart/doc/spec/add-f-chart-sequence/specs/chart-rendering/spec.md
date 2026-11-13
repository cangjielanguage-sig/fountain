# Spec Delta

## ADDED Requirements

### Requirement: 参与者与生命线

`SequenceChart` SHALL 为每个参与者绘制顶部方框与向下生命线；参与者 id MUST 唯一。

#### Scenario: 三个参与者

- **WHEN** `participants` 有 3 项
- **THEN** 输出 3 个 `class="participant"` 与 3 条 `class="lifeline"`

### Requirement: 消息顺序

消息 MUST 按数组顺序自上而下排列；每条消息画水平箭头并在上方显示文本。

#### Scenario: 四条消息

- **WHEN** `messages` 有 4 项
- **THEN** 输出 4 条 `class="message"`

### Requirement: 返回虚线

`type` 为 `return` 或 `dashed` 为 true 时 MUST 使用虚线（`stroke-dasharray`）。

#### Scenario: 返回消息

- **WHEN** 某消息 `type` 为 `return`
- **THEN** 对应线条包含 `stroke-dasharray`

### Requirement: 端点校验

`from` / `to` MUST 指向存在的参与者；否则抛 `InvalidValue`。

#### Scenario: 悬空端点

- **WHEN** 消息 `to` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
