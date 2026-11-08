# Proposal

## Why

蜂巢图按分组把节点聚成簇，簇间连线展示跨组关系，能同时保留分组结构与组间联系，适合技能、标签与社区关系分析。

## What Changes

- 新增 `HiveChart`，`type` 为 `hive`。
- 顶层 `nodes` + `links`；`groupField` 指定分组字段，默认 `group`。
- `nodeRadius` 控制节点半径，默认 10；`clusterGap` 控制簇间距，默认 80。
- 链接 class `hive-link`，节点 class `hive-node`，标签 class `hive-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增蜂巢图需求。

## Impact

- 新增 `src/HiveChart.cj`、`src/HiveChart_test.cj`。
- 复用 `flameColorIndex` 做分组配色。
