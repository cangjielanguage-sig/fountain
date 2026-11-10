# Proposal

## Why

部分依赖图（PDP）固定其他特征、只改变目标特征取值并取模型预测均值，用于观察单一特征对预测结果的边际影响。

## What Changes

- 新增 `PdpChart`，`type` 为 `pdp`。
- `series[0].data` 元素为 `{x: 特征值, y: 预测值}`。
- 专属字段 `feature`（特征名），非空时在绘图区左上角标注。
- 输出 `class="pdp-line"` 折线、`class="pdp-point"` 数据点与 `class="pdp-feature"` 特征标注。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增部分依赖图需求。

## Impact

- 新增 `src/PdpChart.cj`、`src/PdpChart_test.cj`。
