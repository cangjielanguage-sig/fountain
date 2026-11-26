# Proposal

## Why

小提琴图用镜像密度曲线同时展示分布形状与分位数，是箱线图的重要补充。

## What Changes

- 新增 `ViolinChart`，`type` 为 `violin`。
- `series[].data` 为「每组一个数值数组」的嵌套数组；单组时可写扁平数组。
- 每组绘制高斯核密度镜像轮廓（class `violin`），`showBox` 为 true 时叠加箱体与中位线。
- `bandwidth` 可选，缺省用 Silverman 规则。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增小提琴图需求。

## Impact

- 新增 `src/ViolinChart.cj`、`src/ViolinChart_test.cj`。
- 复用 `gaussianKde` / `defaultBandwidth`。
