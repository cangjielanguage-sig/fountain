# Proposal

## Why

螺旋图把周期性数据沿阿基米德螺旋排布，用半径方向展开圈数，能在紧凑的圆形区域内展示多个周期的走势与周期内波动。

## What Changes

- 新增 `SpiralChart`，`type` 为 `spiral`。
- `series[0].data` 元素为 `{period, value}`。
- 专属字段：`turns`（圈数，默认 3）、`startAngle`（默认 −90）、`clockwise`（默认 `true`）。
- 输出 `class="spiral-path"` 螺旋线、`class="spiral-point"` 数据点与 `class="spiral-label"` 周期标签。
- 新增内部 `spiralPoint`，按索引返回相对圆心的坐标。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增螺旋图需求。

## Impact

- 新增 `src/SpiralChart.cj`、`src/SpiralChart_test.cj`。
