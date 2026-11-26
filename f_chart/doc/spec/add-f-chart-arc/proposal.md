# Proposal

## Why

弧线图把节点排成圆周、把关系画成向圆心弯曲的弧，能在一张图里同时呈现节点顺序与关系强度，常用于部门协作、航线与网络流量分析。

## What Changes

- 新增 `ArcChart`，`type` 为 `arc`。
- 顶层 `nodes` + `links`；`nodes` 的元素为 `{id, name?}`，`links` 的元素为 `{source, target, value?}`。
- `arcHeight` 控制弧线向圆心的弯曲程度，默认 0.5；`sort` 取 `value` / `none`。
- 弧线 class `arc-line`，节点 class `arc-node`，标签 class `arc-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增弧线图需求。

## Impact

- 新增 `src/ArcChart.cj`、`src/ArcChart_test.cj`。
- 新增内部 `arcNodeOrder` 便于单测按值排序。
