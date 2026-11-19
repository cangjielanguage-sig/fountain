# Design

## 1. 分组

沿用 `ViolinChart` 的规则：

- 首元素为数组 → 嵌套数组，每组一个数组，组名取 `xAxis.labels` 对应项，缺省用序号。
- 首元素为数字 → 单组，组名取 `labels[0]`、系列名或 `"1"`；混用两种形态抛 `InvalidValue`。

## 2. 统计

- 组内排序后用 `quantileSorted` 取 Q1 / 中位数 / Q3。
- IQR = Q3 − Q1；栅栏为 `[Q1 − 1.5·IQR, Q3 + 1.5·IQR]`。
- 下须取不小于下栅栏的最小值，上须取不大于上栅栏的最大值。

## 3. 绘制

- 箱体宽为槽宽的 0.32 倍，须线与端帽用系列色。
- 原始点用 `swarmOffsets(count, jitter, "both") * 半宽` 抖动，半径 3px。
- 轴、网格、标题与图例复用 `ChartFrame`。
