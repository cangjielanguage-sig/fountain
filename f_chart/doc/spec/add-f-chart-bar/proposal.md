# Proposal

## Why

M0 只建立了接口与规范，还没有任何可运行的图。柱状图是使用频率最高的基础图，也是后续分组、堆叠、百分比堆叠、组合图的共同底座；先用它打通「JSON → 比例尺 → SVG → 测试」的完整链路。

## What Changes

- 新增 `BarChart`，实现 `Chart`，`type` 为 `bar`。
- 新增公共渲染基础设施：`ChartJson`（带路径的 JSON 读取）、`ChartConfig`（通用信封）、`ChartTheme`、`ChartScale`、`ChartFrame`、`ChartSvgKit`。
- 柱状图支持：标题、宽高、内边距、主题调色板、类目轴、数值轴、网格、刻度、图例、柱宽、负值、`null` 缺测。
- 输入校验：`type` 不匹配、`series` 缺失、数据长度与标签不一致、非数值，均抛 `ChartException` 并带路径。

## Capabilities

### New Capabilities

无（在既有 `chart-rendering` 能力上追加需求）。

### Modified Capabilities

- `chart-rendering`：新增柱状图渲染与校验需求。

## Impact

- 新增 `f_chart/src/BarChart.cj`、`BarChart_test.cj` 及公共助手文件。
- 不修改 `Chart` 接口与既有 M0 行为。
