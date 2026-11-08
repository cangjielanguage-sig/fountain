# Design

## 1. 树与布局

与火焰图一致：唯一根、父值不小于子值之和、自底向上、宽度按 `value` 归一化。

## 2. 热度

- 读取 `heatField`（默认 `self`）字段；缺失按 0，存在但非数字抛 `InvalidValue`。
- 记录全部节点的最大热度；比例为 `heat / maxHeat`，最大值为 0 时比例为 0。

## 3. 颜色

`heatFlameColor(ratio, colors)`：

- 三个及以上颜色：复用 `heatmapColor(ratio, c0, c1, c2)`。
- 两个颜色：按 RGB 通道在冷色与热色间线性插值。
- 颜色用 `SvgColor` 解析，非法颜色抛 `InvalidValue`。

## 4. 文字

宽度足够时写节点名；热度比例大于等于 0.6 时用白字，否则用主题文字色。
