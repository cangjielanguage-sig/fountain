# Design

## 1. 数据

每系列解析 `data`（非空数字数组）、`jitter`（默认 0.15，非负）、`dotSize`（默认 7，正数）。类目名取 `xAxis.labels[i]`，缺失用系列名。

## 2. 布局

- 纵轴 `LinearScale`，范围覆盖全部数值并留 8% 余量。
- 每系列一个 `BandScale` 类目带，散点以带中心为基准叠加抖动。

## 3. 抖动

`dotStripOffset(index, jitter, bandwidth)` 用 `sin(index * 12.9898) * 43758.5453` 取小数部分映射到 `[-1, 1]`，再乘 `jitter * bandwidth`。

## 4. 绘制

圆点半径 `dotSize / 2`，填充按系列取主题色，透明系数 0.8。

## 5. 校验

`jitter` 为负、`dotSize` 非正、`data` 为空或元素非数字均抛 `ChartException`。
