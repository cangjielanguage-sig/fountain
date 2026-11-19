# Design

## 1. 数据

每个数据项解析 `name`、`low`、`high`，两者均必须为数字；`low` 可以大于 `high`（表示下降）。

## 2. 轴

- 纵轴 `BandScale`，每个类目一行。
- 横轴 `LinearScale`；`min = xAxis.min ?? min(low, high)`、`max = xAxis.max ?? max(low, high)`，相等时上下各留 1 单位。
- 网格与横轴刻度由 `ChartFrame` 绘制。

## 3. 图元

- 连线从 `xScale(low)` 到 `xScale(high)`，线宽 2px，颜色 `#bdbdbd`。
- `low` 端点圆半径 5px，填充 `#9e9e9e`；`high` 端点圆半径 6px，填充主题第一个色。

## 4. 校验

`series` 数量不为 1、`data` 为空、`low`/`high` 缺失或非数字、`yAxis.labels` 长度不匹配均抛 `ChartException`。
