# Proposal

## Why

混淆矩阵用方阵热力格展示分类模型的预测与真实标签交叉计数，配合行列归一化可快速判断类别间的混淆方向。

## What Changes

- 新增 `ConfusionMatrixChart`，`type` 为 `confusion-matrix`。
- `labels` 为类别名数组；`series[0].data` 为 N×N 数字方阵。
- 专属字段：`normalize`（`none` / `row` / `column`，默认 `none`）、`showValues`（默认 `true`）。
- 输出 `class="confusion-cell"` 方格、`confusion-value` 数值文本、`confusion-label` 行列标签。
- 新增内部 `confusionNormalize(matrix, mode)`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增混淆矩阵需求。

## Impact

- 新增 `src/ConfusionMatrixChart.cj`、`src/ConfusionMatrixChart_test.cj`。
