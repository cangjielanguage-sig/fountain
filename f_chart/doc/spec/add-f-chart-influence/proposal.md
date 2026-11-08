# Proposal

## Why

杠杆图把杠杆值与学生化残差画在同一平面，并按 Cook 距离放大高影响点，帮助回归分析快速定位对模型参数影响过大的异常样本。

## What Changes

- 新增 `InfluenceChart`，`type` 为 `influence`。
- `series[0].data` 的元素为 `{x, y, label?, cooksDistance?}`：`x` 为杠杆值，`y` 为学生化残差。
- 点半径按 `cooksDistance` 相对最大值映射到 4–12px；未提供时为 4px。
- 数据点 class `influence-point`；提供 `label` 时输出 `influence-label` 文本。
- x / y 均为数值轴。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增杠杆图 / 影响图需求。

## Impact

- 新增 `src/InfluenceChart.cj`、`src/InfluenceChart_test.cj`。
- 新增内部 `influenceRadius` 便于单测半径映射。
