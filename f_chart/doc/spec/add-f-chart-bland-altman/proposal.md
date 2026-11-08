# Proposal

## Why

Bland-Altman 图用「均值—差值」散点与一致性界限判断两种测量方法是否可互换，是方法学比较的标准图形。

## What Changes

- 新增 `BlandAltmanChart`，`type` 为 `bland-altman`。
- `series[0].data` 元素为 `{x, y}` 成对测量。
- 每个测量对输出 `class="bland-altman-point"` 散点；并输出 `class="bland-altman-mean"` 均值差线与两条 `class="bland-altman-limit"` 一致性界限线。
- 新增内部 `blandAltmanStats(pairs)`，返回 `[均值差, 下限, 上限]`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增 Bland-Altman 图需求。

## Impact

- 新增 `src/BlandAltmanChart.cj`、`src/BlandAltmanChart_test.cj`。
