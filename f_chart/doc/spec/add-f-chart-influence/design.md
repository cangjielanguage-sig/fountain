# Design

## 1. 数据模型

每个元素解析为 `InfluencePoint(x, y, label, cooksDistance: Option<Float64>)`；`cooksDistance` 缺省或为 null 时按未提供处理。

## 2. 半径映射

`influenceRadius(cooks, maxCooks)`：

- `cooks <= 0` 或 `maxCooks <= 0` 时返回 4。
- 否则返回 `4 + 8 * sqrt(min(cooks / maxCooks, 1))`，最大 12。

## 3. 坐标与绘制

- x / y 均为 `LinearScale`；范围覆盖全部数据，未显式指定时两侧留 5% 余量。
- 点 class `influence-point`，颜色取系列色或调色板第 1 色。
- 标签位于点右侧，class `influence-label`。
- 轴、网格、标题与图例复用 `ChartFrame`。
