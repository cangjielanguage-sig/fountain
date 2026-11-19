# Proposal

## Why

箱线图用五数概括展示分布、偏态与异常值，是分布类图表的核心。M19 提供多类别箱线图。

## What Changes

- 新增 `BoxPlotChart`，`type` 为 `boxplot`。
- `series[0].data` 为对象数组：`{name?, min, q1, median, q3, max, outliers?}`。
- 每个类别绘制箱体、中位线、上下须与端帽，异常值画圆点。
- 校验五数顺序 `min <= q1 <= median <= q3 <= max`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增箱线图需求。

## Impact

- 新增 `src/BoxPlotChart.cj`、`src/BoxPlotChart_test.cj`。
