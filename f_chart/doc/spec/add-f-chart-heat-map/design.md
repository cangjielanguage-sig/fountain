# Design

## 1. 坐标

与分级统计地图一致：SvgBuilder 使用 `SvgViewBox(viewBox...)`；底图路径原样写入 `<path>`。

## 2. 热力点

- 每个点画半径 `radius` 的圆，class `heat-map-point`。
- 比例 `value / maxValue`（最大值 0 时取 0），颜色用 `heatFlameColor` 在 `colorRange` 上插值。
- 按值升序绘制，较大值覆盖在上层。

## 3. 底图

浅灰填充、灰色描边的区域路径，class `heat-map-region`。
