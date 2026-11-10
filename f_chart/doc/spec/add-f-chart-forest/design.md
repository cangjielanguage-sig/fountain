# Design

## 1. 坐标

- x 轴支持 `linear` 与 `log`；范围取 `xAxis.min` / `max`，缺省用全部 `lower` / `upper`。
- 对数轴用 `forestLogPosition(value, min, max)` 归一化到 0–1，再映射到像素。
- 对数刻度用 `forestLogTicks(min, max, base)` 生成范围内各整数次幂，并补上端点。

## 2. 行布局

- 每行一个研究，行高为绘图区高度除以行数；行标签取数据 `label`，右对齐画在绘图区左侧。
- 区间线从 `lower` 到 `upper`，估计值方块居中于 `estimate`。

## 3. 权重

`forestMarkerSize(weight, maxWeight)`：无权重时 8；权重 0 时 6；权重等于最大值时 14，其余按平方根比例插值。

## 4. 画法

- 无效线横贯绘图区高度，虚线。
- x 轴用单位 `LinearScale(0,1)` 与归一化刻度位置复用 `drawXAxisNumeric`。
