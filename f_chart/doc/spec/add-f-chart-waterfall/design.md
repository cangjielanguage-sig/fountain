# Design

## 1. 解析

仅接受一个系列。每项解析 `name`（缺省用 `xAxis.labels[i]`）、`value`、`type`（缺省按 value 符号推断 increase/decrease）。

## 2. 累计

- `running` 初始 0。
- `total`：`start = 0`、`end = value`，`running = value`。
- `increase` / `decrease`：`start = running`、`end = running + value`，`running = end`。
- 记录每根柱的 start/end，用于范围与连接器。

## 3. 绘制

- 柱宽 `bandWidth * 0.55`，x 取 band 中心。
- 颜色：increase 用 `#4caf50`，decrease 用 `#e53935`，total 用 `#607d8b`；`series[0].color` 可整体覆盖。
- 连接器：从上一柱 end 的水平位置到下一柱的起点，虚线 `4 4`，class `connector`。
- 柱顶显示数值文本，class `bar-label`。

## 4. 轴

y 范围覆盖 0 与所有 start/end，留 5% 余量；复用 `ChartFrame.drawYAxis` 与 `drawXAxis`。
