# Proposal

## Why

残差图把回归拟合值与残差画成散点，并用零线作参照，用来检查残差是否随机分布、是否存在异方差或非线性趋势，是回归诊断的标准工具。

## What Changes

- 新增 `ResidualChart`，`type` 为 `residual`。
- `series[0].data` 的元素为 `{x, y}`：`x` 为拟合值，`y` 为残差。
- 始终绘制 y=0 参考线 class `residual-zero`；数据点 class `residual-point`。
- x / y 均为数值轴；y 轴范围强制包含 0。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增残差图需求。

## Impact

- 新增 `src/ResidualChart.cj`、`src/ResidualChart_test.cj`。
- 复用 `LinearScale`、`ChartFrame` 与 `chartNiceTicks`。
