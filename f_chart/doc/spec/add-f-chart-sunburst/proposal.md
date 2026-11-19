# Proposal

## Why

旭日图用同心圆环表达层级占比，内环为父级、外环为子级，能在有限空间内同时看到层级结构与每一层的数值构成。

## What Changes

- 新增 `SunburstChart`，`type` 为 `sunburst`。
- `nodes` 的元素为 `{id, name, parent, value?}`；根节点 `parent` 为 null，叶子节点必须提供 `value`。
- `innerRadius` 为内孔占外半径的比例，默认 0.2；`sort` 取 `value` / `none`，默认 `value`。
- 扇环 class `sunburst-arc`，一级标签 class `sunburst-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增旭日图需求。

## Impact

- 新增 `src/SunburstChart.cj`、`src/SunburstChart_test.cj`。
- 新增内部 `sunburstArcPath` 便于单测扇环路径。
