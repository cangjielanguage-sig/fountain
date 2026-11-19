# Design

## 1. 数据模型

每个元素解析为 `ResidualPoint(x, y)`；x 与 y 均必须为数字。

## 2. 坐标

- x 范围覆盖全部拟合值，未显式指定时两侧留 5% 余量。
- y 范围覆盖全部残差与 0，未显式指定时两侧留 8% 余量。
- 两轴均用 `LinearScale`；x 轴用 `drawXAxisNumeric` 绘制刻度。

## 3. 绘制

- 先画 y=0 参考线，class `residual-zero`，虚线样式。
- 再画散点，class `residual-point`，半径 4px。
- 标题、图例、网格与轴复用 `ChartFrame`。
