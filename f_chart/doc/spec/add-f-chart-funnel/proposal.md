# Proposal

## Why

漏斗图展示流程各阶段的转化与流失，是增长分析的基础图。

## What Changes

- 新增 `FunnelChart`，`type` 为 `funnel`。
- `series[0].data` 为 `{name,value}` 数组；按值从大到小绘制梯形阶段。
- `gap` 控制阶段间距；`showConversion` 默认 true，显示相邻阶段转化率。
- 阶段 class `funnel-stage`，转化文本 class `conversion-label`，阶段标签 class `stage-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增漏斗图需求。

## Impact

- 新增 `src/FunnelChart.cj`、`src/FunnelChart_test.cj`。
- 新增内部 `funnelConversion` 便于单测转化率。
