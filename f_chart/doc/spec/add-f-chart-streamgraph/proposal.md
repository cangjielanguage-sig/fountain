# Proposal

## Why

主题河流图用居中堆叠的平滑色带表达多个类别随时间的构成变化，基线随总量起伏，适合音乐流派热度、话题演化等趋势叙事。

## What Changes

- 新增 `StreamgraphChart`，`type` 为 `streamgraph`。
- `series[].data` MUST 为等长数值数组，类目取自 `xAxis.labels`。
- 专属字段 `baseline` 取 `wiggle`（默认）、`zero` 或 `symmetry`。
- 每个系列绘制一条 `class="stream-band"` 面积带，填充透明系数 0.85。
- 新增内部 `streamBaseline(totals, mode)` 计算每列基线。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增主题河流图需求。

## Impact

- 新增 `src/StreamgraphChart.cj`、`src/StreamgraphChart_test.cj`。
