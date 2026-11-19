# Proposal

## Why

曼哈顿图按染色体铺开全基因组位点，用高度表示显著性，并以交替配色区分染色体，是 GWAS 结果的标准展示方式。

## What Changes

- 新增 `ManhattanChart`，`type` 为 `manhattan`。
- `series[0].data` 元素为 `{x: 位点, y: -log10(p), chromosome}`。
- 专属字段：`threshold`（显著性阈值线）、`chromosomeGap`（染色体间距，默认 0）。
- 输出 `class="manhattan-point"` 散点与 `class="manhattan-threshold"` 阈值线；染色体名称以 `manhattan-chromosome` 文本标注。
- 新增内部 `manhattanPositions(xs, chromosomes, gap)`，返回加入染色体间隔后的横坐标。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增曼哈顿图需求。

## Impact

- 新增 `src/ManhattanChart.cj`、`src/ManhattanChart_test.cj`。
