# Design

## 1. 树构建

解析 `nodes` 为 `{id, name, parent}`，校验 id 唯一、parent 存在、恰好一个根；从根做深度遍历检测环并计算 `depth`。

## 2. 槽位布局

- `leafCount(node)`：无子节点返回 1，否则返回子节点之和。
- 自上而下分配 `[start, end)` 槽区间；节点的槽位中心为 `(start + end - 1) / 2`。
- `vertical`：`x = originX + slot * (nodeWidth + gapX)`、`y = originY + depth * (nodeHeight + levelGap)`。
- `horizontal`：`x = originX + depth * (nodeWidth + levelGap)`、`y = originY + slot * (nodeHeight + gapY)`。
- `gapX` / `gapY` 取 `levelGap * 0.5`，布局整体在 plot 内居中。

## 3. 绘制与连线

- 先画连线再画节点，保证节点盖住线端。
- `vertical` 连线：`M px py V midY H cx V cy`；`horizontal` 连线：`M px py H midX V cy H cx`。
- 节点矩形填充主题色，描边白色；名称在矩形中心、超出 `nodeWidth` 时按字符截断。

## 4. 校验

`nodeWidth`、`nodeHeight` 必须大于 0，`levelGap` 非负；`layout` 仅接受 `vertical` / `horizontal`；环检测失败抛 `InvalidValue`。
