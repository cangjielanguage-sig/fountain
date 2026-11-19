# Design

## 1. 控制限解析

`resolveControlLimits` 按以下顺序求值：

- `center` 缺省时取 `controlMean(values)`。
- `sigma` 缺省时取 `controlStdDev(values)`（样本标准差，分母 n−1；n < 2 时为 0）。
- `ucl` 缺省时为 `center + 3 * sigma`，`lcl` 缺省时为 `center - 3 * sigma`。
- 若 `ucl < lcl` 抛 `InvalidValue`；`sigma` 为负同样抛 `InvalidValue`。

## 2. 绘制

- 类目轴用 `BandScale`；标签来自 `xAxis.labels`，缺省用序号。
- y 轴范围同时覆盖数据值与 `ucl` / `lcl`，未显式指定时两侧留 8% 余量。
- 中心线与上下限横贯绘图区，class 分别为 `control-center` / `control-ucl` / `control-lcl`，右端标注 `CL` / `UCL` / `LCL`。
- 折线 class `control-line`；限内点 `control-point`，越限点 `control-outlier`。
- 图例仅在 `legend.show` 且系列有名字时显示。
