# Design

## 1. 数据

每系列解析 `name`、`data`（`{x,y}` 数组）、可选 `std`（与 `data` 等长的非负数数组）；`metric` 仅做取值校验。

## 2. 轴

- x 轴覆盖全部 `x`，两侧各留 3%。
- y 轴覆盖全部 `y` 与 `y ± std`（若有），上下各留 5%。
- 支持 `xAxis` / `yAxis` 的 `min`、`max`、`values`。

## 3. 绘制

- 每系列一条 2px 折线 + 3.5px 圆点，颜色取主题调色板。
- 标准差带：按 `y − std` 与 `y + std` 组成闭合 path，填充系列色、透明度 0.15。

## 4. 校验

`series` 为空、`data` 为空、`x`/`y` 非数字、`std` 长度不符或为负、`metric` 非法均抛 `ChartException`。
