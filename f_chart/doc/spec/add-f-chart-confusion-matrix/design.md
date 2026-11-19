# Design

## 1. 数据

解析 `labels` 与 `series[0].data`（二维数组），校验方阵、标签数量、单元格非负。

## 2. 归一化

按 `normalize` 计算显示矩阵：`row` 除以行和、`column` 除以列和、`none` 原样；除数为 0 时保持 0。

## 3. 布局

- 左侧预留行标签宽度，顶部预留列标签高度。
- 单元格为正方形，边长取绘图区可容纳 `N × N` 的最大值，整体居中。
- 单元格颜色由 `heatFlameColor(ratio, ["#e3f2fd", "#0d47a1"])` 生成，`ratio` 为归一化值除以矩阵最大值。

## 4. 文本

- 行标签在左侧、右对齐；列标签在顶部、居中。
- `showValues` 为真时在单元格中心显示数值：`normalize == none` 显示整数，否则显示两位小数。

## 5. 校验

`series` 数量不为 1、非方阵、标签数量不符、单元格为负或非数字、`normalize` 非法均抛 `ChartException`。
