# Design

## 1. 布局

- `ChartFrame` 左侧留给类别标签，底部留给数值刻度。
- `BandScale(plot.y, plot.bottom, n)` 分配行。
- `LinearScale(min, max, plot.right, plot.x)` 映射数值。
- 柱高 `min(24, bandWidth * 0.6)`，行内居中。

## 2. 范围

x 范围包含 0；显式 min/max 优先；否则数据范围留 5%。刻度用 `chartNiceTicks` + `chartFormatTick`。

## 3. 绘制

网格为竖直线；类别标签在左侧右对齐；柱 class `bar` / `bar bar-negative`；x 轴复用 `drawXAxisNumeric`。
