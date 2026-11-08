# Design

## 1. 总量

- 叶子总量为 `value`；非叶子总量为子节点总量之和，非叶子的 `value` 忽略。

## 2. 半径与布局

- 全局比例 `k = min(plot.width, plot.height) * 0.45 / sqrt(root.total)`。
- 节点半径 `circlePackingRadius(total, k)`。
- 子节点按总量降序排列，在父圆内按网格排布，每个子圆半径再受单元格尺寸与 `padding` 限制。

## 3. 绘制

先画父圆再画子圆，颜色按节点名散列；半径不小于 18 时在圆心写名称。
