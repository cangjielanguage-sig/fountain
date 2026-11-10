# Design

## 1. 数据

- `nodes` 提供行列标签，顺序即矩阵行列顺序；id 唯一。
- `series[0].data` 必须为 N×N 数值矩阵，N 等于节点数。

## 2. 布局与颜色

- 绘图区按 N 等分，单元格四周留 `cellGap / 2`。
- 颜色比例 `(value - min) / (max - min)`，全部相等时取 0.5；用 `heatmapColor` 在 `colorRange` 上插值。
- 行列标签分别画在底部与左侧，class `tick-label`。

## 3. 数值

`showValues` 为 true 时在单元格中心写数值，深色格用白字。
