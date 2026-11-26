# Design

## 1. 布局

- `bandHeight = plot.height / series.size`；第 i 行基线 `plot.bottom - i × bandHeight`。
- 振幅 `ridgeAmplitude(bandHeight, overlap)`；曲线从基线向上生长。

## 2. 密度

- 每组带宽显式或 Silverman；在全局 x 范围上取 80 个采样点。
- 每组按自身最大密度归一化到振幅。

## 3. 绘制

- 先画上层再画下层，使下层覆盖上层重叠部分。
- 填充 class `ridge-area`，透明度 0.55；描边 class `ridge-line`。
- 组标签在每行基线左侧，class `ridge-label`。
