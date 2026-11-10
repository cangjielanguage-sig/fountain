# Design

## 1. 树构建

- 两遍扫描：先解析全部节点，再按 `parent` 挂到父节点；`parent` 为 null 的进入根列表。
- 校验 id 唯一、父节点存在、恰好一个根、`value > 0`。
- 递归校验每个父节点的 value 不小于其子节点 value 之和。
- 递归计算深度，深度用于确定层数。

## 2. 布局

- 节点宽度 `value / rootValue * plot.width`；子节点从父节点左端开始按顺序累加。
- `frameHeight` 默认 18，并按绘图区高度收缩。
- `bottom-up`：`y = plot.bottom - (depth + 1) * frameHeight`。
- `top-down`：`y = plot.y + depth * frameHeight`。

## 3. 配色

- `name`：`flameColorIndex` 累加名称字节值后取模调色板长度。
- `value`：`value / rootValue` 交给 `heatColor` 分档。

## 4. 文字

矩形宽度大于文本宽度 + 6 时，在左侧内边距处写节点名，class `flame-label`。
