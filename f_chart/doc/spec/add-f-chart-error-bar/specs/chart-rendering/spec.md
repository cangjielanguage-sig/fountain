# Spec Delta

## ADDED Requirements

### Requirement: 误差线绘制

`ErrorBarChart` MUST 为每个数据点绘制一条 `class="error-bar-line"` 竖线、上下两个 `class="error-bar-cap"` 端帽与一个 `class="error-bar-point"` 中心点。

#### Scenario: 四个组

- **WHEN** `data` 有 4 个 `{x, y, low, high}` 对象
- **THEN** 输出 4 条 `error-bar-line`、8 个 `error-bar-cap`、4 个 `error-bar-point`

### Requirement: 误差线类目定位

默认类目轴下 `x` MUST 为字符串；`xAxis.labels` 非空时 MUST 按标签顺序定位，标签缺失时按数据出现顺序生成。

#### Scenario: 标签顺序

- **WHEN** `xAxis.labels` 为 A、B、C、D 且数据 `x` 为 B
- **THEN** 点 B 位于第 2 个槽位

#### Scenario: 未知类目

- **WHEN** `xAxis.labels` 不含数据中的 `x`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 误差线数值轴

`xAxis.type` 为 `linear` 时 `x` MUST 为数字；为 `time` 时 MUST 为 `YYYY-MM-DD` 字符串；此时 x 轴 MUST 使用数值刻度。

#### Scenario: 线性 x

- **WHEN** `xAxis.type` 为 `linear` 且数据 `x` 为 10、20
- **THEN** 输出包含两条 `error-bar-line` 的 SVG

### Requirement: 误差线校验

`low` MUST 不大于 `high`，`y` MUST 落在 `[low, high]` 内；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 边界倒置

- **WHEN** 某点 `low` 大于 `high`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 中心值越界

- **WHEN** 某点 `y` 小于 `low`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
