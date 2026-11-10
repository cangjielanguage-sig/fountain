# Design

## 1. 复用

`PercentBarChart.draw` 直接调用 `BarRenderer.render(data, "percent-bar", BarMode.PercentStacked)`，与 M4 `PercentStackedBarChart` 共用解析、归一化、坐标轴、图例与柱图元。

## 2. 差异

仅 `ChartConfig.parse` 的期望类型字符串为 `percent-bar`，其余行为完全一致。
