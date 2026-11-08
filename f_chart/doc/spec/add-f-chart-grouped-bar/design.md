# Design

## 1. 结构

- `BarRenderer`：内部渲染器，持有 `ChartConfig`、`BarSeries` 列表、`BarMode`。
- `BarChart` / `GroupedBarChart` 只负责校验 `type` 并调用渲染器。
- 后续 `StackedBarChart` / `PercentStackedBarChart` 复用同一渲染器。

## 2. 布局

1. `BandScale` 把 m 个类目映射到绘图区宽度。
2. 分组模式：`slot = bandWidth / n`；第 s 个系列的第 i 根柱：
   `x = bandStart(i) + s * slot + (slot - barWidth) / 2`。
3. `barWidth = min(series.barWidth ?? slot * 0.6, slot * 0.95)`。
4. y 范围取所有系列的最小/最大值；正值从 0 向上，负值从 0 向下。
5. 颜色、图例、轴、网格沿用 M1 的 `ChartFrame`。

## 3. 兼容

`BarChart` 仍按 `simple` 模式渲染；M1 的 17 个用例与输出保持不变（重构后全量回归）。
