# Design

## 1. 解析

与 `LineChart` 一致：先判定每个系列的数据形状，全部为对象则连续模式，全部为数值则类目模式，混合抛 `InvalidValue`。

## 2. 路径

- 分段：遇到 `null` 结束当前段。
- 面积路径：`M p0 ... L pn` 之后追加 `L (xn, baselineY) L (x0, baselineY) Z`。
- 平滑时顶边用 `Q` 命令，底边仍为直线。
- 基线像素：`yScale.scale(0)`，并钳制到绘图区 `[plot.y, plot.bottom]`。

## 3. y 范围

数据最小值与 0 取较小者，最大值与 0 取较大者；显式 `min` / `max` 优先；无数据时 0–1。正值在最大值上加 5% 余量。

## 4. 样式

- 填充色取系列色，`areaStyle.opacity` 默认 0.3。
- 描边色取系列色，线宽 2，class `line`。
- `symbol` 默认 `none`，可设为 `circle` / `square` / `diamond`。

## 5. 轴

类目轴复用 `ChartFrame.drawXAxis`；数值/时间轴复用 `drawXAxisNumeric`，刻度格式化沿用 `ChartTime.formatDays`。
