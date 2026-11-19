# Proposal

## Why

饼图用扇区面积展示少量类别的占比，是构成类图表的基础。

## What Changes

- 新增 `PieChart`，`type` 为 `pie`。
- `series[0].data` 为 `{name,value}` 对象数组；值必须非负且总和大于 0。
- `startAngle` 控制起始角度（度，默认 0，从 12 点方向开始）。
- `showPercent` 默认 true，在扇区内显示百分比标签 class `pie-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增饼图需求。

## Impact

- 新增 `src/PieChart.cj`、`src/PieChart_test.cj`。
- 新增内部 `pieFractions` 便于单测占比。
