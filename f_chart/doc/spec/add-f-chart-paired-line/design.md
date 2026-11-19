# Design

## 1. 数据

解析 `series[0].data` 的 `name`、`before`、`after`；两者必须为非负数字。

## 2. 布局

两个时间点取 `BandScale(plot.x, plot.right(), 2)` 的中心；纵轴范围覆盖全部 `before` / `after`，缺省上下各留 5%，`yAxis.min` / `yAxis.max` 可覆盖。

## 3. 绘制

- 每项一条 1.5px 斜线，颜色按项索引取主题色。
- 两端圆点半径 3.5px，同色。
- 名称写在第二个点右侧 8px 处。

## 4. 校验

`series` 数量不为 1、`data` 为空、`before`/`after` 缺失或非数字、时间点数量不为 2 均抛 `ChartException`。
