# Proposal

## Why

增益图展示按模型评分排序后头部样本的累计捕获比例，与对角线基准对比可判断模型是否比随机抽样更有效。

## What Changes

- 新增 `GainChart`，`type` 为 `gain`。
- `series[0].data` 元素为 `{x: 样本比例, y: 累计捕获比例}`。
- 输出 `class="gain-line"` 折线、`class="gain-point"` 数据点与 `class="gain-baseline"` 对角线。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增增益图需求。

## Impact

- 新增 `src/GainChart.cj`、`src/GainChart_test.cj`。
