# Proposal

## Why

棒棒糖图用细茎加圆头替代实心柱，在类目较多时减少墨水占用，突出数值端点，适合转化率、得分等单值比较。

## What Changes

- 新增 `LollipopChart`，`type` 为 `lollipop`。
- 与柱状图同数据形状：`xAxis.labels` 为类目，`series[i].data` 为数值数组，允许 `null` 缺测。
- 每个数值绘制一条 `class="lollipop-stem"` 细线与一个 `class="lollipop-head"` 圆点，系列级 `symbolSize` 控制圆点直径（默认 8）。
- 纵轴范围 MUST 包含 0，支持 `yAxis.min` / `yAxis.max` 覆盖。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增棒棒糖图需求。

## Impact

- 新增 `src/LollipopChart.cj`、`src/LollipopChart_test.cj`。
