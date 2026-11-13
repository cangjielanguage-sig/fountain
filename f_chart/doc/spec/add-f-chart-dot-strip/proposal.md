# Proposal

## Why

豆图（点带图）把每个观测画成沿类目列的抖动散点，适合小样本、离散取值等场景，能直观看到重叠与离群。

## What Changes

- 新增 `DotStripChart`，`type` 为 `dot-strip`。
- `series[i].data` 为一组数值，`xAxis.labels[i]` 为类目名。
- 专属字段：`jitter`（水平抖动比例，默认 0.15）、`dotSize`（点直径，默认 7）。
- 每个观测输出 `class="dot-strip-dot"` 圆点。
- 新增内部 `dotStripOffset`，按索引生成确定性抖动。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增豆图需求。

## Impact

- 新增 `src/DotStripChart.cj`、`src/DotStripChart_test.cj`。
