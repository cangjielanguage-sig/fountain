# Proposal

## Why

流程图表达步骤、分支与汇合，是项目与流程类图的基础。M9 提供节点-边模型与自动分层布局。

## What Changes

- 新增 `Flowchart`，`type` 为 `flowchart`。
- 顶层 `nodes: [{id,label,shape,x?,y?,width?,height?}]` 与 `edges: [{source,target,label?}]`。
- `shape` 支持 `rect` / `round` / `diamond` / `ellipse` / `parallelogram` / `document`。
- `layout` 支持 `vertical`（默认）、`horizontal`、`manual`。
- 自动布局按入边分层；边带箭头与可选标签。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增流程图需求。

## Impact

- 新增 `src/Flowchart.cj`、`src/Flowchart_test.cj`；`ChartSvgKit` 增加 `ellipse`。
