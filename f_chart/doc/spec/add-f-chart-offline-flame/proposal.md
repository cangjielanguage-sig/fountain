# Proposal

## Why

离线火焰图只渲染指定调用栈子树，并可按最大深度截断，适合在报告或文档中聚焦某条热点路径，避免整棵树过于拥挤。

## What Changes

- 新增 `OfflineFlameChart`，`type` 为 `offline-flame`。
- `nodes` 的元素为 `{id, name, parent, value}`。
- `root` 指定起始节点 id，缺省为整棵树的根。
- `maxDepth` 限制显示深度，缺省不限。
- 节点矩形 class `offline-flame-node`，标签 class `offline-flame-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增离线火焰图需求。

## Impact

- 新增 `src/OfflineFlameChart.cj`、`src/OfflineFlameChart_test.cj`。
- 复用 `flameColorIndex` 与火焰图树构建规则。
