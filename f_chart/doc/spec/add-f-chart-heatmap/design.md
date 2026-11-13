# Design

## 1. 矩阵解析

- `series[0].data` 必须是数组的数组，每行元素为数字，行长度一致。
- 记录全局最小值 `minValue` 与最大值 `maxValue`。
- 归一化：`ratio = (value - minValue) / (maxValue - minValue)`；`maxValue == minValue` 时取 0.5。

## 2. 颜色

`heatmapColor(ratio, low, mid, high)` 用 `SvgColor` 解析三色，按 RGB 通道线性插值：

- `ratio <= 0.5`：低色 → 中色，参数 `ratio * 2`。
- `ratio > 0.5`：中色 → 高色，参数 `(ratio - 0.5) * 2`。
- 输出 `#rrggbb`。

## 3. 布局

- 绘图区按列数、行数均分。
- 单元格矩形四周各留 `cellGap / 2` 的间隙。
- x 轴用 `BandScale` 绘制列标签；y 轴逐行绘制行标签（anchor end）。
- `showValues` 为 true 时在单元格中心写数值；深色格用白字，浅色格用主题文字色。

## 4. 图例

`legend.show` 且系列有名字时，用中色作为图例色块，复用 `ChartFrame.drawLegend`。
