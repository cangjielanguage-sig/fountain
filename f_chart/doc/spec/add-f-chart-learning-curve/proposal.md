# Proposal

## Why

学习曲线对比训练集与验证集在不同样本量下的得分，用于判断模型是欠拟合还是过拟合，以及增加数据是否还有收益。

## What Changes

- 新增 `LearningCurveChart`，`type` 为 `learning-curve`。
- `series[i].data` 元素为 `{x: 样本量, y: 得分}`；可选 `series[i].std` 为每点标准差。
- 专属字段：`metric`（`score` / `loss`）、`shade`（是否绘制标准差带，默认 `false`）。
- 输出 `class="learning-line"` 折线、`class="learning-point"` 数据点与 `class="learning-band"` 标准差带。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增学习曲线需求。

## Impact

- 新增 `src/LearningCurveChart.cj`、`src/LearningCurveChart_test.cj`。
