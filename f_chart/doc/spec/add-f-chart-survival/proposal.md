# Proposal

## Why

Kaplan-Meier 生存曲线用阶梯线表达随时间变化的生存概率，并标出删失与置信带，是临床试验与可靠性分析中最常用的生存分析可视化。

## What Changes

- 新增 `SurvivalChart`，`type` 为 `survival`。
- `series[]` 支持多条曲线，每条 `data` 的元素为 `{time, survival, censored?}`。
- `confidence` 默认 false，为 true 时按二项标准误绘制近似置信带。
- `showCensors` 默认 true，删失点用 `+` 标记。
- 阶梯线 class `survival-line`，点 `survival-point`，删失标记 `survival-censor`，置信带 `survival-band`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增 Kaplan-Meier 生存曲线需求。

## Impact

- 新增 `src/SurvivalChart.cj`、`src/SurvivalChart_test.cj`。
- 新增内部 `survivalConfidence` 便于单测置信区间近似。
