# Design

## 1. 数据

`xAxis.labels` 恰好 2 个（缺省为 `["前", "后"]`）；每系列解析 `name`、`data`（2 个数字）与可选 `color`。

## 2. 布局

- 两个时间点的 x 坐标取 `BandScale(plot.x, plot.right(), 2)` 的两个 `center`。
- 纵轴范围覆盖全部数值，缺省上下各留 5% 余量；`yAxis.min` / `yAxis.max` 可覆盖。
- 右侧预留 64px 用于系列名称。

## 3. 绘制

- 每个系列一条 2px 斜线，颜色取主题调色板或 `color`。
- 两端圆点半径 4px。
- 系列名写在第二个点右侧 8px 处，垂直居中于终点。

## 4. 校验

时间点数量不为 2、系列数据长度不为 2、数据非数字、`series` 为空均抛 `ChartException`。
