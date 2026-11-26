# Proposal

## Why

时间线图按时间顺序排列关键事件，用轴线和节点串起里程碑，适合产品发布、项目节点、历史沿革等叙事型展示。

## What Changes

- 新增 `TimelineChart`，`type` 为 `timeline`。
- 数据来自 `events: [{date, title, description?, group?}]`。
- 专属字段 `orientation` 取 `horizontal`（默认）或 `vertical`。
- 轴线 class `timeline-axis`，事件点 class `timeline-dot`，文本 class `timeline-date` / `timeline-title` / `timeline-desc`。
- 水平布局事件交替置于轴线上下两侧；垂直布局日期在左、标题与描述在右。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增时间线图需求。

## Impact

- 新增 `src/TimelineChart.cj`、`src/TimelineChart_test.cj`。
