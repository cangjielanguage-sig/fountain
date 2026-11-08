# Design

## 1. 半径

全局收集所有 size 的最小/最大值；`radius = minR + (size - minSize)/(maxSize - minSize) × (maxR - minR)`；退化时取区间中值。

## 2. 绘制

- 圆点 class `bubble`，填充透明度 0.6，同色描边。
- `label` 非空时在圆心下方显示文本，class `bubble-label`。
- 两轴为连续数值轴，复用 `drawXAxisNumeric` 与 `drawYAxis`。

## 3. 颜色

每系列取 `series[].color` 或调色板；多系列显示图例。
