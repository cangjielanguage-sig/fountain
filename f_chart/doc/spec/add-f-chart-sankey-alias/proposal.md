# Proposal

## Why

规格文档把 M67 定义为 M36 桑基图的别名；需要用一个变更显式记录「不新增实现、复用 `SankeyChart`」的约定，并用文档示例做回归验证。

## What Changes

- 不新增图类型与源文件。
- `M67` 输入 `type` 为 `sankey` 时继续由 `SankeyChart` 处理。
- 新增别名回归测试，验证文档示例能生成含桑基流量带的 SVG。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增桑基图别名需求。

## Impact

- 新增 `src/SankeyAlias_test.cj`。
- 无新增实现文件。
