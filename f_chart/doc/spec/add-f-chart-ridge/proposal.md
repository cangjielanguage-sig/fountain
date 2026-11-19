# Proposal

## Why

山脊图把多组分布上下错位排列，便于比较分布形状随分组的变化。

## What Changes

- 新增 `RidgeChart`，`type` 为 `ridge`。
- `series[]` 每组一个数值数组；`overlap` 控制曲线重叠程度（0–1，默认 0.5），`bandwidth` 可选。
- 每组绘制填充的核密度曲线，class `ridge-area`，描边 class `ridge-line`。
- 左侧显示组标签，class `ridge-label`；x 轴为连续数值轴。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增山脊图需求。

## Impact

- 新增 `src/RidgeChart.cj`、`src/RidgeChart_test.cj`。
- 新增内部 `ridgeAmplitude` 便于单测重叠系数。
