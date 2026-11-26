# Design

## 1. 布局

与 M11 相同：`ChartFrame` 左侧类别标签、底部数值刻度；`BandScale` 行、`LinearScale` 数值。

## 2. 绘制

- 每行中心（多系列时按子槽）画 stem：`kit.line(baseline, y, valueX, y)`，class `stem`。
- 圆点 `kit.circle(valueX, y, symbolSize/2)`，class `dot`。
- 负值 stem 从 baseline 向左；点落在负值位置。

## 3. 范围

包含 0；显式 min/max 优先；其余同 M11。
