# Design

## 1. 数据

解析 `series[0].data` 的 `x`、`y`，按 `x` 升序排序后绘制。

## 2. 轴

- x 轴缺省范围 `[min(0, dataMin), max(1, dataMax)]`。
- y 轴缺省范围 `[min(0, dataMin), max(1, dataMax)]`。

## 3. 绘制

- 折线 2px 主题第一色，数据点半径 3.5px。
- 对角线从 `(xMin, yMin)` 到 `(xMax, yMax)`，`#9e9e9e` 虚线。

## 4. 校验

`series` 数量不为 1、`data` 为空、`x`/`y` 非数字均抛 `ChartException`。
