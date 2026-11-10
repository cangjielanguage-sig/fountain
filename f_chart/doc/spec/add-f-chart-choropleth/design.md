# Design

## 1. 坐标

- SvgBuilder 使用 `SvgViewBox(viewBox[0], viewBox[1], viewBox[2], viewBox[3])` 建立用户坐标系。
- 背景矩形覆盖整个 viewBox；标题画在 viewBox 顶部居中。

## 2. 区域

- 每个 region 的 `path` 直接写入 `<path d="...">`，填充色由值决定。
- 颜色比例：`(value - min) / (max - min)`，全部相等时取 0.5。
- `colorRange` 两个颜色时用 `heatFlameColor` 线性插值，三个及以上时用 `heatmapColor`。

## 3. 标签

- `showLabels` 为 true 时，用 `pathCentroid` 提取路径中所有坐标点的平均值作为标签位置。
- 标签内容为 region 的 `name`。
