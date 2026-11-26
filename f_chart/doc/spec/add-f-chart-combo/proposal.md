# Proposal

## Why

实际仪表盘常需要在同一绘图区叠加柱、线、点，用不同视觉通道表达不同量纲。M7 在既有柱/线/散点渲染能力上实现组合图，并支持右侧数值轴。

## What Changes

- 新增 `ComboChart`，`type` 为 `combo`。
- `series[].type` 取 `bar` / `grouped-bar` / `stacked-bar` / `percent-stacked-bar` / `line` / `scatter`。
- 支持 `series[].axis` 为 `left` / `right`，配合 `yAxis2`。
- 柱类按 `stack` 分组：同组堆叠，不同组并列；百分比堆叠组归一化到 100%。
- 折线与散点叠加在柱之上；散点 `x` 可写类目名或类目下标。
- `ChartConfig` 增加 `yAxis2`；`ChartFrame` 增加右侧轴与右标签宽度。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增组合图与双轴需求。

## Impact

- 新增 `src/ComboChart.cj`、`src/ComboChart_test.cj`。
- 扩展 `ChartConfig`、`ChartFrame`；既有图行为不变。
