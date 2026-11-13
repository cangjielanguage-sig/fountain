# Proposal

## Why

节点-链接图把实体画成节点、关系画成连线，是服务依赖、社交网络与知识图谱最基础的可视化形式；支持力导向、环形与手工坐标三种布局。

## What Changes

- 新增 `NodeLinkChart`，`type` 为 `node-link`。
- 顶层 `nodes` 的元素为 `{id, name?, group?, x?, y?}`，`links` 的元素为 `{source, target, value?}`。
- `layout` 取 `force`（默认）/ `circular` / `manual`；`linkDistance`、`charge` 控制力导向参数。
- 连线 class `node-link-edge`，节点 class `node-link-node`，标签 class `node-link-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增节点-链接图需求。

## Impact

- 新增 `src/NodeLinkChart.cj`、`src/NodeLinkChart_test.cj`。
- 新增内部 `nodeLinkWidth` 便于单测连线宽度。
