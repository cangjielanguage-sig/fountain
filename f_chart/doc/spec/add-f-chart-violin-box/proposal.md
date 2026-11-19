# Proposal

## Why

小提琴图展示完整密度形状，箱线图突出分位数与异常值；两者叠加能在同一组数据上同时看到分布轮廓、中心趋势与离群点，减少并排比较时的视觉跳转。

## What Changes

- 新增 `ViolinBoxChart`，`type` 为 `violin-box`。
- `series[0].data` 支持「每组一个数值数组」的嵌套数组；单组时可写扁平数值数组。
- `bandwidth` 控制核密度带宽；`showBox` 默认 true；`showOutliers` 默认 true。
- 小提琴轮廓 class `violin-box-violin`；箱体 `violin-box-box`；中位线 `violin-box-median`；须线 `violin-box-whisker`；端帽 `violin-box-cap`；异常值 `violin-box-outlier`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增小提琴 + 箱线组合图需求。

## Impact

- 新增 `src/ViolinBoxChart.cj`、`src/ViolinBoxChart_test.cj`。
- 复用 `gaussianKde` / `defaultBandwidth` / `quantileSorted` 与 `boxScatterBounds`。
