# Design

## 1. 数据

每个数据项解析 `name`、`value`、`target`、`ranges`；`ranges` 校验为正数且严格递增，重复或倒序抛 `InvalidValue`。

## 2. 横轴范围

- `min = xAxis.min ?? 0`。
- `max` 优先取 `xAxis.max`，否则取 `max(最后区间上界, value, target)`。
- 刻度用 `chartNiceTicks` 生成，标签按 `xAxis.labelFormat` 格式化。

## 3. 行布局

- 纵轴使用 `BandScale`，每个类目一行。
- 背景色带高度为 `bandWidth * 0.7`，按 `ranges` 分段，颜色由 `bulletRangeColor(index)` 从 `#efefef` 到 `#d0d0d0`。
- 值条高度为 `bandWidth * 0.28`，居中，颜色取主题第一个色。
- 目标线从行顶 20% 画到 80%，线宽 3px，颜色 `#444444`。

## 4. 校验

`series` 数量不为 1、`data` 为空、`value`/`target` 为负、`ranges` 非法、`yAxis.labels` 长度不匹配均抛 `ChartException`。
