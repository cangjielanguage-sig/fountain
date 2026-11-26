# Design

## 1. 分组

- 按 `groupField` 读取分组名，空值归入空字符串分组。
- 分组顺序按首次出现顺序稳定排列。

## 2. 布局

- 各分组中心均匀分布在绘图区中心、半径取短边 0.32 倍的圆上。
- 组内节点围成小圆，小圆半径取 `min(clusterGap / 2, nodeRadius * 2.2)`；单节点时位于组中心。

## 3. 绘制

- 先画链接，灰色 1.2px，class `hive-link`。
- 节点半径 `nodeRadius`，颜色按分组名经 `flameColorIndex` 映射。
- 节点名画在圆心，白色，class `hive-label`。
