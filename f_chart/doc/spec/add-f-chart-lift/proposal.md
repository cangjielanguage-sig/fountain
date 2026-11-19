# Proposal

## Why

提升图把不同样本比例下的 lift 连成曲线，并叠加基准线 1，用于判断模型在头部样本上的增益是否显著优于随机。

## What Changes

- 新增 `LiftChart`，`type` 为 `lift`。
- `series[0].data` 元素为 `{x: 样本比例, y: lift}`。
- 专属字段 `baseline`（默认 1）。
- 输出 `class="lift-line"` 折线、`class="lift-point"` 数据点与 `class="lift-baseline"` 基准虚线。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增提升图需求。

## Impact

- 新增 `src/LiftChart.cj`、`src/LiftChart_test.cj`。
