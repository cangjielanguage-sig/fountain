## Context

TUI 子包已有字符画布、坐标框、ANSI 真彩色与标签宽度工具。火焰图不需要坐标轴，只需要标题与一个矩形绘图区；节点按树形层级和值比例布局。

## Goals

- 与 SVG `flame` 共用 JSON 字段和校验语义。
- 每个节点显示为真彩色字符块，颜色稳定且可区分。
- 在 80×24 的终端内可读；`bottom-up` / `top-down` 都支持。

## Decisions

### 树解析与校验

在 TUI 内复用根包的 `FlameNode`、`flameColorIndex`、`heatColor`，但独立实现解析与校验，避免改动 SVG 渲染路径。校验规则与 `FlameChart` 保持一致：单根、id 唯一、parent 存在、value > 0、子节点和不超父节点、无环。

### 布局

- 使用 `TuiFrame(config, 0)` 提供标题与绘图区；不绘制坐标轴。
- 节点列范围按 `value / root.value` 递归分配；子节点依次占用父节点左侧部分，父节点剩余宽度保留给“自身”部分。
- 每层行数 `rowsPerDepth = min(frameHeight, floor(plot.height / (maxDepth + 1)))`，至少 1。`frameHeight` 在 TUI 中按字符行解释，缺省值 18 会被可用高度压缩。
- `bottom-up`：根在绘图区底部；`top-down`：根在顶部。

### 颜色

- `colorBy = "name"`：`theme.colorAt(flameColorIndex(name, palette.size))`。
- `colorBy = "value"`：`heatColor(value / root.value)`。
- 标签颜色由背景亮度决定：亮度 ≥ 150 用黑色，否则用白色。

### 标签

块宽 ≥ 名称显示宽度 + 2 时，在块内左侧留 1 列后写名称；标签行取块的首行。窄块跳过标签，避免破坏矩形。

## Risks

- 终端字符宽高比导致火焰图视觉上偏扁；通过每层多行与字符块填充缓解。
- 大量窄节点无法显示标签；与 SVG 的“宽度不足不显示标签”策略一致。
