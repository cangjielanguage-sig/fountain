# Design

## 1. 坐标

- SvgBuilder 使用 `SvgViewBox(viewBox...)`；缺省 viewBox 取画布尺寸。
- 底图路径直接写入 `<path>`，浅灰填充、灰色描边。
- 点按 `(x, y)` 直接定位。

## 2. 半径

`dotDensityRadius(weight, radius)`：`weight <= 1` 时返回基准半径，否则返回 `radius * sqrt(weight)`。

## 3. 绘制

- 先画所有底图路径，再画点，点使用系列主色。
- 标题画在 viewBox 顶部居中。
