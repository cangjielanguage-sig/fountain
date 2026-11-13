# Design

## 1. 与火焰图的关系

冰柱图与火焰图共享树构建、宽度分配、校验与配色规则，仅默认方向相反：

- `top-down`：`y = plot.y + depth * frameHeight`。
- `bottom-up`：`y = plot.bottom - (depth + 1) * frameHeight`。

## 2. 宽度

节点宽度 `value / rootValue * plot.width`；子节点从父节点左端按顺序累加，父节点 value 必须容纳子节点之和。

## 3. 配色与文字

- `name`：`flameColorIndex(name, paletteSize)`。
- `value`：`heatColor(value / rootValue)`。
- 矩形宽度足够时在左侧 4px 处写名称，class `icicle-label`。
