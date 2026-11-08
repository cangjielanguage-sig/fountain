# Design

## 1. 取整

- 求总和，按 `value / total * cells` 得到精确格数。
- 先取 `floor`，再按小数部分降序（相同则按下标升序）逐个补 1，直到累计等于 `cells`。

## 2. 布局

- 行数 `rows = ceil(cells / columns)`。
- 方格边长取绘图区能容纳 `columns × rows` 的最大正方形，格间距固定 2px。
- 整体在绘图区居中；每类连续分配方格，颜色取主题调色板。

## 3. 图例

在方格下方按类别顺序输出 `名称 值` 文本，超过绘图区宽度时另起一行。

## 4. 校验

`cells`、`columns` 必须为正整数；`series` 数量不为 1、`data` 为空、`value` 为负或总和为 0 抛 `InvalidValue`。
