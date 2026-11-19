# Proposal

## Why

象形图用重复的小图标表示数量，把抽象数值映射为可数的图形，适合团队人数、设备数量等离散量级展示。

## What Changes

- 新增 `PictogramChart`，`type` 为 `pictogram`。
- `series` 为多个系列，每系列 `data` 元素为 `{name, value}`。
- 专属字段：`icon`（`person` / `circle` / `square`，或 SVG path 字符串）、`unit`（每个图标代表的数值）、`columns`（每行图标数，默认 10）。
- 图标 class `pictogram-icon`，行标签 class `pictogram-label`。
- 新增内部 `pictogramCount`（向上取整的图标数量）与 `pictogramIconPath`（生成图形路径）。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增象形图需求。

## Impact

- 新增 `src/PictogramChart.cj`、`src/PictogramChart_test.cj`。
