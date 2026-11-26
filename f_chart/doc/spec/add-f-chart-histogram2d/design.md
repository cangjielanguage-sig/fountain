# Design

## 1. 分箱

- 统计 x/y 数据范围；退化时扩为 ±0.5。
- 下标 `floor((value - min) / width)`，钳制到箱范围。
- counts 展平存储，索引 `y * binsX + x`。

## 2. 绘制

- 颜色由 `heatColor(count / maxCount)` 从浅蓝到深蓝。
- 方形：每个非零单元一个矩形，class `cell`。
- 六边形：单元中心画半径 `min(cellW, cellH) * 0.55` 的六边形，class `hexagon`。
- 两轴复用 `drawXAxisNumeric` 与 `drawYAxis`。
