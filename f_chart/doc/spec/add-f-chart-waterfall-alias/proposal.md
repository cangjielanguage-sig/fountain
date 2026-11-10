# Proposal

## Why

技术文档把瀑布图同时列为 M16 与 M87 两个条目，二者数据形状与 `type` 完全一致。本变更 M87 明确其为 M16 的别名，不新增实现，只补规格说明与回归测试。

## What Changes

- 不新增图表类；`type` 为 `waterfall` 时由既有 `WaterfallChart` 渲染。
- 新增 `WaterfallAlias_test.cj`，回归文档 M16/M87 示例。
- 规格记录别名关系，避免后续重复实现。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：记录瀑布图别名条目。

## Impact

- 新增 `src/WaterfallAlias_test.cj`；不新增生产代码。
