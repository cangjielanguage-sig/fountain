# Design

## 1. 区域

- `regions` 解析为 `{id, name, path, centerX, centerY}`，质心用 `pathCentroid`。
- 底图浅灰填充，class `flow-map-region`。

## 2. 流向路径

- `points` 提供时按顺序生成折线；否则用 source / target 的质心连直线。
- 路径用系列色描边、`stroke-opacity` 0.6，线宽由 `flowMapWidth` 决定。
- 按 value 升序绘制，大流量覆盖在上层。

## 3. 宽度

`flowMapWidth(value, maxValue)`：`value <= 0` 或 `maxValue <= 0` 时返回 1；否则 `1 + 4 * sqrt(value / maxValue)`。

## 4. 兼容字段

`source` / `target` 为主字段；同时接受 `from` / `to` 作为别名。
