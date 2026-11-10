# Proposal

## Why

PR 曲线在类别不平衡时比 ROC 更能反映模型对正例的识别质量，水平基线给出正例比例的随机基准，平均精确率 AP 则把曲线概括为单一指标。

## What Changes

- 新增 `PrChart`，`type` 为 `pr`。
- `series[0].data` 的元素为 `{x: 召回率, y: 精确率}`，按 x 升序绘制。
- `baseline` 可选，提供时绘制精确率水平基线。
- `ap` 可选，提供时在绘图区左上角标注 `AP = ...`。
- 曲线 class `pr-line`，点 `pr-point`，基线 `pr-baseline`，AP 标注 `pr-ap`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增 PR 曲线需求。

## Impact

- 新增 `src/PrChart.cj`、`src/PrChart_test.cj`。
- 复用 `LinearScale` / `ChartFrame`。
