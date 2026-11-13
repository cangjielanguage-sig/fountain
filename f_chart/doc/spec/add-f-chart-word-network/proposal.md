## Why

文本分析场景需要展示词语共现关系。`f_chart` 已有通用节点-链接图（M62），但词网络以「词权重决定节点半径、词名置于节点内」为特征，且沿用 `nodes` + `links` 的顶层结构，需要独立实现以保证词云类的语义完整。

## What Changes

- 新增 `WordNetworkChart`（`type` 为 `word-network`），实现 `Chart` 接口。
- 顶层 `nodes: [{id, name, weight?}]` 与 `links: [{source, target, value}]`；`weight` 决定节点半径，`value` 决定连线宽度。
- 支持 `layout`（`force` / `circular`，默认 `force`）与 `linkDistance`（默认 100）。
- 节点内居中绘制词名；`force` 布局采用确定性迭代，保证输出可复现。

## Capabilities

### New Capabilities

- `chart-rendering`：新增词网络图的 JSON 契约与渲染行为。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/src/WordNetworkChart.cj` 与 `f_chart/src/WordNetworkChart_test.cj`。
- 复用 `ChartConfig`、`ChartFrame`、`ChartSvgKit`、`nodeLinkWidth` 与 `flameColorIndex`。
