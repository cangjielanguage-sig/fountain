## Why

仪表盘用于展示单一指标相对目标区间的完成情况。`f_chart` 的指标类图表已有子弹图（M76），但缺少角度化、带阈值分段的仪表盘表达。

## What Changes

- 新增 `GaugeChart`（`type` 为 `gauge`），实现 `Chart` 接口。
- `min`（默认 0）、`max`（默认 100）、`startAngle`（默认 -120）、`endAngle`（默认 120）。
- `thresholds: [{value, color}]` 将量程切分为若干色带；未提供时使用单段底色。
- `series[0].data` 取第一项 `{name, value}`；绘制指针与中心数值。
- 校验量程、角度、阈值递增与数值范围。

## Capabilities

### New Capabilities

- `chart-rendering`：新增仪表盘的 JSON 契约与渲染行为。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/src/GaugeChart.cj` 与 `f_chart/src/GaugeChart_test.cj`。
- 复用 `ChartConfig`、`ChartFrame`、`ChartSvgKit`。
