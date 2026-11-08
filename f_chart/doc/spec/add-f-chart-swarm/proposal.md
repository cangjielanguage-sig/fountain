# Proposal

## Why

蜂群图/抖动图在小样本时展示原始点，避免重叠，适合与箱线图、小提琴图互补。

## What Changes

- 新增 `SwarmChart`，`type` 为 `swarm`。
- `series[].data` 为「每组一个数值数组」的嵌套数组；单组时可写扁平数组。
- `jitter` 控制抖动宽度（0–1，默认 0.3），`side` 取 `both` / `left` / `right`。
- 点按数值排序后分配确定性抖动偏移，避免重叠。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增蜂群图需求。

## Impact

- 新增 `src/SwarmChart.cj`、`src/SwarmChart_test.cj`。
- 新增内部 `swarmOffsets` 便于单测抖动分布。
