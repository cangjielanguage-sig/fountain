# Spec Delta

## ADDED Requirements

### Requirement: PR 曲线

`PrChart` MUST 按 x 升序为每个数据点绘制 `class="pr-point"` 圆点，并用 `class="pr-line"` 折线连接。

#### Scenario: 六个工作点

- **WHEN** `data` 有 6 个 `{x, y}` 点
- **THEN** 输出 6 个 `class="pr-point"` 与 1 条 `class="pr-line"`

### Requirement: PR 基线

提供 `baseline` 时 MUST 输出 1 条 `class="pr-baseline"` 水平虚线；未提供时不输出。

#### Scenario: 带基线

- **WHEN** `baseline` 为 0.12
- **THEN** 输出 1 条 `class="pr-baseline"`

#### Scenario: 无基线

- **WHEN** 未提供 `baseline`
- **THEN** 输出 0 条 `class="pr-baseline"`

### Requirement: AP 标注

提供 `ap` 时 MUST 输出 1 个 `class="pr-ap"` 文本，内容含 `AP` 与数值；`ap` MUST 在 0–1 之间。

#### Scenario: 带 AP

- **WHEN** `ap` 为 0.72
- **THEN** 输出 1 个 `class="pr-ap"` 且内容含 0.72

#### Scenario: AP 越界

- **WHEN** `ap` 为 −0.1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: PR 校验

`x` / `y` MUST 为 0–1 的数字；`baseline` 提供时 MUST 在 0–1 之间；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 越界工作点

- **WHEN** 某点 `y` 为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
