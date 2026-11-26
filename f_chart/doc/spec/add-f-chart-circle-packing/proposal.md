# Proposal

## Why

圆堆积图用嵌套圆面积表达层级占比，父圆包住子圆，能在一个紧凑的圆形区域内呈现文件类型、预算科目等层级构成。

## What Changes

- 新增 `CirclePackingChart`，`type` 为 `circle-packing`。
- `nodes` 的元素为 `{id, name, parent, value?}`；根节点 `parent` 为 null，叶子必须提供 `value`。
- `padding` 控制子圆间距，默认 2。
- 圆 class `circle-packing-circle`，标签 class `circle-packing-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增圆堆积图需求。

## Impact

- 新增 `src/CirclePackingChart.cj`、`src/CirclePackingChart_test.cj`。
- 新增内部 `circlePackingRadius` 便于单测面积半径。
