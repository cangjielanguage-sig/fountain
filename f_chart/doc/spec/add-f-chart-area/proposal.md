# Proposal

## Why

折线图只画线，面积图用填充强调累计量与规模。M14 在折线能力上增加面积路径，复用类目/连续轴与缺测分段。

## What Changes

- 新增 `AreaChart`，`type` 为 `area`。
- `series[].data` 支持数值数组与 `{x,y}` 对象；`xAxis.type` 支持 `category` / `linear` / `time`。
- 面积从曲线下沿填充到 0 基线；`areaStyle.opacity` 控制填充透明度（默认 0.3）。
- 默认不画顶点符号；`symbol` 可显式开启；`smooth` 复用二次贝塞尔。
- y 轴范围默认包含 0。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增面积图需求。

## Impact

- 新增 `src/AreaChart.cj`、`src/AreaChart_test.cj`。
- 复用 `LinePoint` / `LinePixel` / `lineRange` / `ChartFrame.drawXAxisNumeric`。
