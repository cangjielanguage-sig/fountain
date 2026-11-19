# Proposal

## Why

泳道图把流程节点按负责角色分带，能同时表达「谁做什么」与「先后顺序」，适合审批流、跨部门协作等场景。

## What Changes

- 新增 `SwimlaneChart`，`type` 为 `swimlane`。
- `lanes` 元素为 `{id, name}`；`nodes` 元素带 `lane`；`edges` 元素为 `{source, target, label?}`，与流程图一致。
- 专属字段 `direction` 取 `horizontal`（默认）或 `vertical`。
- 泳道带 class `swimlane-lane`，带名 class `swimlane-label`，节点 class `swimlane-node`，节点文本 `swimlane-node-label`，连线 class `swimlane-edge`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增泳道图需求。

## Impact

- 新增 `src/SwimlaneChart.cj`、`src/SwimlaneChart_test.cj`。
