# Design

## 1. 数据模型

每个元素解析为 `ErrorBarPoint(label, x, y, low, high)`：

- 类目轴：`label` 为 `x` 字符串，`x` 为标签下标。
- 数值轴：`x` 为数字；时间轴先经 `ChartTime.parseDays` 转天数。
- 校验 `low <= high` 且 `low <= y <= high`。

## 2. 坐标

- 类目轴用 `BandScale`，点位于槽位中心。
- 数值/时间轴先求 x 范围（含 `xAxis.min` / `xAxis.max` 覆盖），再建 `LinearScale`。
- y 范围覆盖全部 `low` / `high` / `y`，未显式指定时两侧留 8% 余量。

## 3. 绘制

- 竖线从 `high` 到 `low`，class `error-bar-line`。
- 端帽宽为槽宽的 0.3 倍，最长 12px，class `error-bar-cap`。
- 中心点半径 3px，class `error-bar-point`。
- 轴、网格、标题与图例复用 `ChartFrame`。
