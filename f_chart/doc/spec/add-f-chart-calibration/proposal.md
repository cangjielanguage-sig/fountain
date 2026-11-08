# Proposal

## Why

校准曲线把预测概率与实际观测频率对照，配合 45° 对角线可判断模型是否系统性高估或低估风险。

## What Changes

- 新增 `CalibrationChart`，`type` 为 `calibration`。
- `series[0].data` 元素为 `{x: 预测概率, y: 实际频率}`。
- 专属字段：`diagonal`（默认 `true`）、`binCount`（可选，正奇数校验）。
- 输出 `class="calibration-line"` 折线、`class="calibration-point"` 数据点与 `class="calibration-diagonal"` 对角线。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增校准曲线需求。

## Impact

- 新增 `src/CalibrationChart.cj`、`src/CalibrationChart_test.cj`。
