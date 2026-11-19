# Design

## 1. 网格

- 去重并排序 x/y 坐标，构造 `nx × ny` 网格。
- 点数必须等于 `nx × ny` 且每个组合都有值，否则抛 `InvalidValue`。

## 2. 分层

- `min/max` 取所有 value 的极值。
- `band = floor((value - min) / (max - min) × levels)`，钳制到 `[0, levels-1]`。
- 颜色由 `heatColor(band / (levels - 1))` 映射。

## 3. 绘制

- 每个网格单元一个矩形 class `contour-cell`。
- 相邻单元 band 不同时，在共享边画 `contour-line`。
- 两轴复用 `drawYAxis` 与 `drawXAxisNumeric`。
