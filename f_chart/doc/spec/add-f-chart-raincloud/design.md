# Design

## 1. 数据

每系列解析 `data`（非空数字数组）、可选 `bandwidth`、三个布尔开关（默认 `true`）。类目名取 `xAxis.labels[i]`，缺失时用系列名。

## 2. 布局

- 纵轴 `LinearScale`，范围覆盖全部数值并留 8% 余量。
- 每个系列占一个 `BandScale` 类目带。
- 云在带中心右侧：密度归一化到 `bandWidth * 0.35`，覆盖最小值到最大值。
- 雨在带中心左侧：`swarmOffsets(count, bandWidth * 0.15, "left")` 作为水平偏移基础，再左移 `bandWidth * 0.18`。
- 箱在带中心：宽 `bandWidth * 0.1`，中位线与须线同色。

## 3. 绘制顺序

云 → 雨 → 箱 → 中位线 → 须线 → 异常值，保证箱体覆盖散点。

## 4. 校验

`data` 为空、元素非数字、`bandwidth` 非正均抛 `ChartException`。
