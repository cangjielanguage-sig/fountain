# Design

## 1. 数据

每系列解析 `name`、`data`（数字或 `null`）、`color` 与 `symbolSize`（默认 8，必须大于 0）；`xAxis.labels` 为空时按最长数据生成 `1..n`。

## 2. 轴

- 横轴 `BandScale`，多系列时在类目带内均分槽位。
- 纵轴 `LinearScale`，范围至少包含 0；`yAxis.min` / `yAxis.max` 可覆盖，二者相等时上下各扩 1。
- 网格、纵轴与横轴由 `ChartFrame` 绘制。

## 3. 图元

- 茎：从 `yScale(0)` 到 `yScale(value)` 的 2px 竖线，颜色取系列色。
- 圆头：半径 `symbolSize / 2`，同色填充。

## 4. 校验

`series` 为空、数据非数字且非 null、`symbolSize` 非正、类目长度不匹配均抛 `ChartException`。
