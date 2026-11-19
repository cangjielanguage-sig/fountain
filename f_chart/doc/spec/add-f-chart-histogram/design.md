# Design

## 1. 分箱

- `bins` 缺省为 `max(1, round(sqrt(n)))`。
- `width = (max - min) / bins`；`max == min` 时范围扩为 `[min-0.5, min+0.5]`。
- 下标 `floor((value - min) / width)`，钳制到 `[0, bins-1]`。

## 2. 绘制

- 每箱矩形从 `scale(binStart)` 到 `scale(binEnd)`，高度按频数；class `histogram-bar`。
- 零频箱跳过；柱色取调色板首位。
- x 轴用 `drawXAxisNumeric`；y 轴用 `drawYAxis`。

## 3. 范围

x 范围默认数据 min/max，显式 `xAxis.min/max` 优先；y 范围 `0..maxCount * 1.05`。
