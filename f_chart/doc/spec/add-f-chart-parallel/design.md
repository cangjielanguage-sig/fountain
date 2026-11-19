# Design

## 1. 维度

- 每个维度解析 name/min/max；缺省 min/max 从所有样本该列取值。
- 若仍相等，min -= 0.5、max += 0.5。

## 2. 布局

- 维度轴在绘图区等距分布；单维度时居中。
- 样本顶点 y = bottom - normalize × height。

## 3. 绘制

- 轴：竖直线 + 顶部维度名。
- 样本：路径 class `parallel-line`，颜色取系列色或调色板。
