# Proposal

## Why

累积频率图（ECDF）直接展示经验分布函数，不依赖分箱，适合比较两组响应时间、测量值等连续数据的整体分布差异。

## What Changes

- 新增 `EcdfChart`，`type` 为 `ecdf`。
- `series[].data` 为原始数值数组，内部排序后计算累计频率。
- 每个系列输出一条 `class="ecdf-line"` 阶梯折线。
- 新增内部 `ecdfPoints(values)`，返回 `[值, 累计频率]` 序列。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增累积频率图需求。

## Impact

- 新增 `src/EcdfChart.cj`、`src/EcdfChart_test.cj`。
