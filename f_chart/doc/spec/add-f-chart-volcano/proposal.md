# Proposal

## Why

火山图以 `log2FC` 为横轴、`−log10(p)` 为纵轴展示差异表达，配合阈值线一眼区分显著上调、显著下调与不显著项。

## What Changes

- 新增 `VolcanoChart`，`type` 为 `volcano`。
- `series[0].data` 元素为 `{x: log2FC, y: -log10(p), label?}`。
- 专属字段：`foldChangeThreshold`（默认 1）、`pThreshold`（默认 1.3）、`upColor`、`downColor`。
- 输出 `class="volcano-point"` 散点并附加 `volcano-up` / `volcano-down` / `volcano-nonsig`；阈值线 class `volcano-threshold`；显著项标签 `volcano-label`。
- 新增内部 `volcanoCategory(x, y, foldChangeThreshold, pThreshold)`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增火山图需求。

## Impact

- 新增 `src/VolcanoChart.cj`、`src/VolcanoChart_test.cj`。
