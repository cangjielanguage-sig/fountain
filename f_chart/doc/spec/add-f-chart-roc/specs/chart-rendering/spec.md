# Spec Delta

## ADDED Requirements

### Requirement: ROC 曲线

`RocChart` MUST 按 x 升序为每个数据点绘制 `class="roc-point"` 圆点，并用 `class="roc-line"` 折线连接。

#### Scenario: 六个工作点

- **WHEN** `data` 有 6 个 `{x, y}` 点
- **THEN** 输出 6 个 `class="roc-point"` 与 1 条 `class="roc-line"`

### Requirement: ROC 对角线

`diagonal` 默认为 true，此时 MUST 输出 1 条 `class="roc-diagonal"` 虚线；为 false 时不输出。

#### Scenario: 关闭对角线

- **WHEN** `diagonal` 为 false
- **THEN** 输出 0 条 `class="roc-diagonal"`

### Requirement: AUC 标注

提供 `auc` 时 MUST 输出 1 个 `class="roc-auc"` 文本，内容含 `AUC` 与数值；`auc` MUST 在 0–1 之间。

#### Scenario: 带 AUC

- **WHEN** `auc` 为 0.86
- **THEN** 输出 1 个 `class="roc-auc"` 且内容含 0.86

#### Scenario: AUC 越界

- **WHEN** `auc` 为 1.2
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: ROC 校验

`x` / `y` MUST 为 0–1 的数字；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 越界工作点

- **WHEN** 某点 `x` 为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
