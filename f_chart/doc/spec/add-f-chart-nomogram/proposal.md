# Proposal

## Why

列线图把多个预测变量的取值折算为分值，再通过总分刻度映射到事件风险，让临床或业务人员无需计算即可从变量读数得到风险估计。

## What Changes

- 新增 `NomogramChart`，`type` 为 `nomogram`。
- `variables` 为 `[{name, range: [min, max], points: [minP, maxP]}]`。
- `totalPoints` 为总分范围 `[min, max]`；`risk` 为 `[{points, probability}]` 映射。
- 每个变量一行刻度尺，另加总分与风险两行。
- 变量尺 class `nomogram-variable`，总分尺 `nomogram-total`，风险刻度 `nomogram-risk-tick`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增列线图需求。

## Impact

- 新增 `src/NomogramChart.cj`、`src/NomogramChart_test.cj`。
- 新增内部 `nomogramPosition` 便于单测位置换算。
