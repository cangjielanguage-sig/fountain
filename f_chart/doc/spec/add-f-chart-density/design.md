# Design

## 1. 带宽

样本标准差 `σ = sqrt(Σ(x-mean)²/(n-1))`；`h = 1.06 · σ · n^(-1/5)`；`h <= 0` 时取 1。

## 2. 网格

每个系列在 `[min-3h, max+3h]` 上取 100 段（101 点）求密度；全局 x 范围为各系列网格的并集。

## 3. 绘制

- 折线路径 class `density-line`，线宽 2。
- `fill` 为 true 时先画 `density-area`（闭合到基线，透明度 0.25），再画折线。
- 颜色取 `series[].color` 或调色板。

## 4. 轴

y 轴从 0 到全局最大密度 × 1.05；x 轴用 nice 刻度与 `drawXAxisNumeric`。
