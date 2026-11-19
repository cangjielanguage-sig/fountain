# Design

## 1. 布局

- `circular`：按输入顺序均匀分布在绘图区中心、半径为短边 0.35 倍的圆上。
- `manual`：使用节点 `x` / `y`；缺失抛 `MissingField`。
- `force`：以环形位置为初始值，执行固定 80 轮确定性迭代：
  - 节点间斥力 `charge / distance²`；
  - 链接弹簧向 `linkDistance` 收敛；
  - 轻微向绘图区中心回拉。
  - 不引入随机数，保证相同输入输出一致。

## 2. 绘制

- 先画连线，线宽由 `nodeLinkWidth` 决定，class `node-link-edge`。
- 再画节点圆（半径 8），颜色按 `group` 名称散列到调色板，class `node-link-node`。
- 节点名画在圆点下方，class `node-link-label`。

## 3. 宽度

`nodeLinkWidth(value, maxValue)`：`value <= 0` 或 `maxValue <= 0` 时返回 1；否则 `1 + 3 * sqrt(value / maxValue)`。
