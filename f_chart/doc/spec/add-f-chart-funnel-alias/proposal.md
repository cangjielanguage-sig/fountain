# Proposal

## Why

技术文档把漏斗图同时列为 M35 与 M86 两个条目，二者数据形状与 `type` 完全一致。本变更 M86 明确其为 M35 的别名，不新增实现，只补规格说明与回归测试。

## What Changes

- 不新增图表类；`type` 为 `funnel` 时由既有 `FunnelChart` 渲染。
- 新增 `FunnelAlias_test.cj`，回归文档 M35/M86 示例。
- 规格记录别名关系，避免后续重复实现。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：记录漏斗图别名条目。

## Impact

- 新增 `src/FunnelAlias_test.cj`；不新增生产代码。
