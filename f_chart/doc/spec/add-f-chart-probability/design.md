# Design

## 1. 理论分位数

复用 `qqTheoryQuantiles(count, distribution)`，位置取 `p_i = (i + 0.5) / n`：

- `normal`：标准正态分位数。
- `uniform`：`p_i`。
- `exponential`：`-ln(1 - p_i)`。

## 2. 参考线

复用 `qqFitLine(theory, sorted)` 得到 `[截距, 斜率]`，在 x 轴范围两端画线。

## 3. 绘制

- x / y 均为 `LinearScale`，范围覆盖数据并在两侧留 5% 余量；显式 `min` / `max` 优先。
- 散点 class `probability-point`，参考线 class `probability-line`（虚线）。
- 轴、网格、标题与图例复用 `ChartFrame`。
