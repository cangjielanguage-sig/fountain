# Design

## 1. 数据

解析 `series[0].data` 的 `period` 与 `value`；`turns` 必须大于 0，`startAngle` 任意，`clockwise` 默认 `true`。

## 2. 坐标

- `spiralPoint(i, count, turns, startAngle, clockwise, maxRadius)`：
  - `direction = clockwise ? 1 : -1`
  - `angle = startAngle + direction * turns * 360 * i / max(count - 1, 1)`
  - `radius = maxRadius * (i + 1) / count`
  - 返回 `[radius * cos(angle), radius * sin(angle)]`
- 圆心为画布中心，`maxRadius` 为短边的一半减 40px。

## 3. 绘制

- 螺旋线按点序列连成折线，线宽 1.5px，颜色 `#b0bec5`。
- 数据点半径按 `value` 线性映射 3–8px，颜色取主题调色板。
- 周期标签放在点外侧 10px 处。

## 4. 校验

`turns` 非正、`data` 为空、`period` 非字符串、`value` 为负或非数字均抛 `ChartException`。
