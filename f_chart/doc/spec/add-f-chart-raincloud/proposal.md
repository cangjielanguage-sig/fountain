# Proposal

## Why

雨云图把密度曲线（云）、原始散点（雨）与箱线摘要（箱）组合在同一列，既能看分布形状，也保留原始观测与稳健统计量。

## What Changes

- 新增 `RaincloudChart`，`type` 为 `raincloud`。
- `series[i].data` 为一组原始数值，`xAxis.labels[i]` 为组名。
- 专属字段：`showCloud` / `showRain` / `showBox`（默认均 `true`）、`bandwidth`（密度带宽）。
- 输出 `class="raincloud-cloud"` 半小提琴、`class="raincloud-rain"` 散点、`class="raincloud-box"` 箱体与 `raincloud-median` / `raincloud-whisker` / `raincloud-outlier`。
- 复用 `gaussianKde` / `defaultBandwidth` / `boxScatterBounds` / `swarmOffsets`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增雨云图需求。

## Impact

- 新增 `src/RaincloudChart.cj`、`src/RaincloudChart_test.cj`。
