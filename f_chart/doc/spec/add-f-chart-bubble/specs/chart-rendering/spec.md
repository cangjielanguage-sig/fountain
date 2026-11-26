# Spec Delta

## ADDED Requirements

### Requirement: 气泡半径映射

`BubbleChart` SHALL 把 `size` 线性映射到 `sizeRange` 指定的半径区间；所有气泡尺寸相同时取区间中值。

#### Scenario: 线性映射

- **WHEN** `sizeRange` 为 `[6,34]`，size 最小值与最大值分别映射
- **THEN** 半径分别为 6 与 34

### Requirement: 气泡绘制

每个数据点 MUST 输出一个 `class="bubble"` 圆；提供 `label` 时 MUST 输出 `class="bubble-label"` 文本。

#### Scenario: 四个气泡

- **WHEN** 数据有 4 个点且都带 `label`
- **THEN** 输出 4 个 `class="bubble"` 与 4 个 `class="bubble-label"`

### Requirement: 气泡图校验

`sizeRange` MUST 为两个非负数且上限不小于下限；`x/y/size` MUST 为数值；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法 sizeRange

- **WHEN** `sizeRange` 为 `[20, 10]`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 缺少 size

- **WHEN** 某点没有 `size`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`
