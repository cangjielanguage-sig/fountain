# Proposal

## Why

控制图把过程测量值按时间顺序描点，并叠加中心线与上下控制限，用于识别过程是否处于统计受控状态。

## What Changes

- 新增 `ControlChart`，`type` 为 `control`。
- `xAxis.labels` 为时间点标签；`series[0].data` 为按时间顺序的数值。
- `series[0]` 可给 `center` / `ucl` / `lcl`；缺省时按均值与 ±3σ 计算。
- 可选 `sigma` 指定标准差；未给时用样本标准差（分母 n−1）。
- 折线 class `control-line`，数据点 `control-point`，越限点 `control-outlier`；中心线 `control-center`，上下限 `control-ucl` / `control-lcl`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增控制图需求。

## Impact

- 新增 `src/ControlChart.cj`、`src/ControlChart_test.cj`。
- 新增内部 `controlMean` / `controlStdDev` / `resolveControlLimits` 便于单测。
