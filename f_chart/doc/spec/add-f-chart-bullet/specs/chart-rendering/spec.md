# Spec Delta

## ADDED Requirements

### Requirement: 子弹图区间色带

`BulletChart` MUST 为每个数据项的每个区间绘制一个 `class="bullet-range"` 矩形，色带宽度 MUST 对应该区间上界在横轴上的位置，颜色 MUST 由 `bulletRangeColor` 按区间序号返回由浅到深的灰色。

#### Scenario: 三个区间

- **WHEN** 3 个数据项、每项 3 个区间
- **THEN** 输出 9 个 `bullet-range` 矩形

### Requirement: 子弹图值条与目标线

每个数据项 MUST 输出一个 `class="bullet-value"` 矩形表示 `value`，并输出一条 `class="bullet-target"` 竖线表示 `target`。

#### Scenario: 三个数据项

- **WHEN** `data` 有 3 项
- **THEN** 输出 3 个 `bullet-value` 与 3 个 `bullet-target`

### Requirement: 子弹图横轴范围

横轴最小值 MUST 取 `xAxis.min`（缺省 0），最大值 MUST 取 `xAxis.max`；未给出 `max` 时 MUST 覆盖 `ranges` 最后一项、`value` 与 `target` 的最大值。

#### Scenario: 未给最大值

- **WHEN** 区间上界为 [50, 75, 100]、value 为 72、target 为 80
- **THEN** 横轴范围至少覆盖 0 到 100

### Requirement: 子弹图校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`value`、`target` MUST 为非负数字；`ranges` MUST 非空、全为正数且严格递增；`yAxis.labels` 非空时长度 MUST 等于 `data` 长度；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 区间非递增

- **WHEN** `ranges` 为 [50, 50, 100]
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 目标缺失

- **WHEN** 某数据项没有 `target`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`
