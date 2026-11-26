# Design

## 1. 解析

仅接受 1 个系列。每项读取 name（缺省用 `xAxis.labels[i]`）、五个统计量与可选 `outliers`。

## 2. 绘制

- 类别槽位由 `BandScale` 分配；箱宽 `bandWidth * 0.5`，最小 12。
- 须：min→q1 与 q3→max 两条竖线，class `whisker`。
- 端帽：min 与 max 处各一条水平短线，class `whisker-cap`。
- 箱体：q1→q3 矩形，class `box`；中位线横向贯穿箱体，class `median`。
- 异常值：半径 3 的圆，class `outlier`。

## 3. 范围

y 范围覆盖所有 min/max 与异常值，留 5% 余量；显式 `yAxis.min/max` 优先。
