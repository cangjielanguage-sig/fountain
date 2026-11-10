# Proposal

## Why

甘特图是项目进度排期的标准图。M8 需要把任务的时间区间、进度和依赖关系映射到时间轴。

## What Changes

- 新增 `GanttChart`，`type` 为 `gantt`。
- 顶层 `tasks`：`{id, name, start, end, progress?, dependsOn?, lane?, color?}`。
- 时间轴复用 `ChartTime`；任务按行排布，进度叠加，依赖画折线箭头。
- `dependsOn` 指向不存在的任务 id 时抛 `InvalidValue`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增甘特图需求。

## Impact

- 新增 `src/GanttChart.cj`、`src/GanttChart_test.cj`。
