# Design

## 1. 布局

- `horizontal`：泳道等分绘图区高度，左侧预留 90px 写泳道名；节点宽 120、高 40，在泳道内按序等距分布。
- `vertical`：泳道等分绘图区宽度，顶部预留 30px 写泳道名；节点在泳道内按序等距分布。
- 泳道背景交替使用 `#fafafa` 与 `#f0f0f0`，分隔线用主题轴色。

## 2. 节点

矩形填充主题色（按泳道索引取色）、白字居中；文本超出宽度时截断。

## 3. 连线

- `horizontal`：源右侧中点 → 目标左侧中点，路径为 `M sx sy H midX V ty H tx`，箭头三角指向右。
- `vertical`：源底部中点 → 目标顶部中点，路径为 `M sx sy V midY H tx V ty`，箭头三角指向下。
- 连线上提供 `label` 时在折点处写 `swimlane-edge-label`。

## 4. 校验

泳道为空、id 重复、节点 lane 未知、节点 id 重复、边端点未知、direction 非法均抛 `ChartException`。
