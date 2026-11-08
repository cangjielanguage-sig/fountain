# Design

## 1. 解析

每个系列 `data` 为对象数组；`x` 按 `xAxis.type` 解析（time → `ChartTime.parseDays`，否则数字），`y` 必须为数字。

## 2. 范围与轴

x/y 均用 `lineRange`：显式 min/max 优先，否则数据范围留 5%；刻度用 `chartNiceTicks`。x 轴用 `LinearScale(min,max,right,left)` 映射，标签用 `drawXAxisNumeric`。

## 3. 点

`symbolSize` 作为直径；`circle` 半径为一半，`square`/`diamond` 用边长。class 固定 `symbol`。
